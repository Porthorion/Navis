[CmdletBinding()]
param(
  [string]$RepoRoot,
  [Parameter(Mandatory = $true)][string]$SourceDatabase,
  [Parameter(Mandatory = $true)][string]$CredentialFile,
  [Parameter(Mandatory = $true)][string]$SongId,
  [Parameter(Mandatory = $true)][string]$SecondSongId,
  [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell leaves $PSScriptRoot empty in parameter defaults when the
# script is started with -File, so the defaults are resolved here.
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $OutputRoot) {
  $OutputRoot = Join-Path $RepoRoot "build\windows-smtc-diagnostics\$(Get-Date -Format 'yyyyMMddTHHmmssZ')-clone"
}
# Blocking on GMTC's WinRT calls from a single-threaded apartment is cancelled
# by COM's message filter (RPC_E_CALL_CANCELED).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'MTA') {
  throw 'Run this script with powershell.exe -MTA -File tool\windows_smtc_diagnostics.ps1 ...'
}
$AppUserModelId = 'com.navis.app.navis'
$Handshake = Join-Path $OutputRoot 'handshake.json'
$CloneDatabase = Join-Path $OutputRoot 'navis-diagnostics.sqlite'
$AppLog = Join-Path $OutputRoot 'navis.log'
$script:AppProcess = $null
$script:BaseUrl = $null
$script:Token = $null

if ($SongId -eq $SecondSongId) {
  throw 'SongId and SecondSongId must be different.'
}
foreach ($path in @($RepoRoot, $SourceDatabase, $CredentialFile)) {
  if (-not (Test-Path $path)) { throw "Required path is missing: $path" }
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Copy-Item -LiteralPath $SourceDatabase -Destination $CloneDatabase

function Invoke-Api {
  param([Parameter(Mandatory = $true)][string]$Method, [Parameter(Mandatory = $true)][string]$Path, [object]$Body)
  $headers = @{ Authorization = "Bearer $script:Token" }
  $params = @{ Method = $Method; Uri = "$script:BaseUrl$Path"; Headers = $headers; UseBasicParsing = $true }
  if ($PSBoundParameters.ContainsKey('Body')) {
    $params.ContentType = 'application/json'
    $params.Body = ($Body | ConvertTo-Json -Compress)
  }
  return Invoke-RestMethod @params
}

function Wait-Until {
  param([Parameter(Mandatory = $true)][scriptblock]$Condition, [string]$Description, [int]$TimeoutSeconds = 90)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 500
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out waiting for $Description. See $AppLog"
}

function Invoke-WinRtOperation {
  # Windows PowerShell exposes WinRT async operations as bare COM objects, so
  # the result type cannot be discovered by reflection and is passed in.
  param([Parameter(Mandatory = $true)][object]$Operation, [type]$ResultType = [bool])
  $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
      $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
      $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
  $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  return $task.GetAwaiter().GetResult()
}

function Get-NavisSession {
  $managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
  $manager = Invoke-WinRtOperation ($managerType::RequestAsync()) -ResultType $managerType
  return $manager.GetSessions() | Where-Object { $_.SourceAppUserModelId -eq $AppUserModelId } | Select-Object -First 1
}

function Wait-ForNavisSession {
  Wait-Until -Description 'the Navis GMTC session' -Condition { $null -ne (Get-NavisSession) }
  return Get-NavisSession
}

function Get-PlaybackStatus { return Invoke-Api GET '/v1/playback/status' }

function Wait-ForPresentation {
  Wait-Until -Description 'the restored application presentation' -TimeoutSeconds 60 -Condition {
    $status = Invoke-Api GET '/v1/presentation/status'
    $status.appReady -and $status.screenshotReady -and $status.route -and $status.route -ne '/loading'
  }
}


function Stop-Navis {
  if ($null -eq $script:AppProcess) { return }
  try { Invoke-Api POST '/v1/shutdown' | Out-Null } catch {}
  # Process.Kill(bool) is unavailable in Windows PowerShell (.NET Framework).
  if (-not $script:AppProcess.WaitForExit(30000)) {
    & taskkill.exe /PID $script:AppProcess.Id /T /F | Out-Null
    if ($LASTEXITCODE -ne 0 -and -not $script:AppProcess.HasExited) { throw 'Unable to stop the diagnostics process tree.' }
  }
  $script:AppProcess = $null
}

function Start-Navis {
  Remove-Item $Handshake -Force -ErrorAction SilentlyContinue
  $arguments = @(
    'run', '-d', 'windows', '--profile', '--no-pub',
    '--dart-define=NAVIS_UPDATE_CHANNEL=dev',
    '--dart-define=NAVIS_APP_ID_SUFFIX=.dev',
    '--dart-define=NAVIS_APP_NAME=Navis SMTC Diagnostics',
    '--dart-define=NAVIS_SYNC_DIAGNOSTICS=true',
    '--dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone',
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$Handshake",
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_ROOT=$OutputRoot",
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CloneDatabase",
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$CredentialFile"
  )
  # Start-Process joins arguments with spaces without quoting them, so every
  # argument carries its own quotes.
  $argumentLine = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $script:AppProcess = Start-Process -FilePath 'flutter' -ArgumentList $argumentLine -WorkingDirectory $RepoRoot -RedirectStandardOutput $AppLog -RedirectStandardError "$AppLog.stderr" -PassThru
  Wait-Until -Description 'the authenticated diagnostics API handshake' -TimeoutSeconds 300 -Condition { Test-Path $Handshake -PathType Leaf }
  $handshake = Get-Content -Raw $Handshake | ConvertFrom-Json
  $script:BaseUrl = "http://127.0.0.1:$($handshake.port)"
  $script:Token = $handshake.token
  Invoke-Api GET '/v1/health' | Out-Null
}

try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  # Windows PowerShell resolves WinRT types only after this explicit load.
  $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
  Start-Navis
  Invoke-Api POST '/v1/playback/queue' @{ songIds = @($SongId, $SecondSongId) } | Out-Null
  Wait-Until -Description 'first queued song to play' -Condition { (Get-PlaybackStatus).songId -eq $SongId -and (Get-PlaybackStatus).playing }

  $session = Wait-ForNavisSession
  # A source database may carry shuffle or repeat from an earlier run; start
  # from sequential playback so Next and Previous have fixed targets.
  $repeatNone = [Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType = WindowsRuntime]::None
  if (-not (Invoke-WinRtOperation $session.TryChangeShuffleActiveAsync($false))) { throw 'GMTC shuffle-off command was rejected.' }
  if (-not (Invoke-WinRtOperation $session.TryChangeAutoRepeatModeAsync($repeatNone))) { throw 'GMTC repeat-off command was rejected.' }
  Wait-Until -Description 'sequential playback' -Condition { $status = Get-PlaybackStatus; $status.shuffleMode -eq 'none' -and $status.repeatMode -eq 'none' }
  # The session appears before the whole queue reaches the player, so the
  # transport capabilities (Next in particular) are published shortly after.
  Wait-Until -Description 'GMTC metadata and transport capabilities' -Condition {
    $session = Get-NavisSession
    if ($null -eq $session) { return $false }
    $media = Invoke-WinRtOperation $session.TryGetMediaPropertiesAsync() ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $controls = $session.GetPlaybackInfo().Controls
    -not [string]::IsNullOrWhiteSpace($media.Title) -and $controls.IsPauseEnabled -and $controls.IsNextEnabled -and $controls.IsPreviousEnabled
  }
  $session = Get-NavisSession
  $mediaType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
  $media = Invoke-WinRtOperation ($session.TryGetMediaPropertiesAsync()) -ResultType $mediaType
  $playback = $session.GetPlaybackInfo()
  $timelineBefore = $session.GetTimelineProperties()
  # The timeline is republished about once a second; a short track may also
  # change in between, so require a newer publication with a new position.
  Wait-Until -Description 'GMTC timeline progress' -TimeoutSeconds 10 -Condition {
    $timelineAfter = (Get-NavisSession).GetTimelineProperties()
    $timelineAfter.LastUpdatedTime -gt $timelineBefore.LastUpdatedTime -and
      $timelineAfter.Position -ne $timelineBefore.Position
  }

  if (-not (Invoke-WinRtOperation $session.TryPauseAsync())) { throw 'GMTC pause command was rejected.' }
  Wait-Until -Description 'GMTC pause to reach Navis' -Condition { -not (Get-PlaybackStatus).playing }
  if (-not (Invoke-WinRtOperation $session.TryPlayAsync())) { throw 'GMTC play command was rejected.' }
  Wait-Until -Description 'GMTC play to reach Navis' -Condition { (Get-PlaybackStatus).playing }
  if (-not (Invoke-WinRtOperation $session.TrySkipNextAsync())) { throw 'GMTC next command was rejected.' }
  Wait-Until -Description 'GMTC next to reach Navis' -Condition { (Get-PlaybackStatus).songId -eq $SecondSongId }
  # Previous restarts a song that has played for more than three seconds, so a
  # slow start may need a second press to reach the first song.
  for ($press = 1; $press -le 2; $press++) {
    if (-not (Invoke-WinRtOperation $session.TrySkipPreviousAsync())) { throw 'GMTC previous command was rejected.' }
    try {
      Wait-Until -Description 'GMTC previous to reach Navis' -TimeoutSeconds 10 -Condition { (Get-PlaybackStatus).songId -eq $SongId }
      break
    } catch {
      if ($press -eq 2) { throw }
    }
  }
  # A paused seek must land at five seconds: a WinRT TimeSpan is in 100 ns
  # ticks, and a unit error clamps it to the end of the song.
  if (-not (Invoke-WinRtOperation $session.TryPauseAsync())) { throw 'GMTC pause before seek was rejected.' }
  Wait-Until -Description 'GMTC pause before seek to reach Navis' -Condition { -not (Get-PlaybackStatus).playing }
  $seekPositionTicks = [TimeSpan]::FromSeconds(5).Ticks
  if (-not (Invoke-WinRtOperation $session.TryChangePlaybackPositionAsync($seekPositionTicks))) { throw 'GMTC seek command was rejected.' }
  Wait-Until -Description 'paused GMTC seek to five seconds' -TimeoutSeconds 10 -Condition {
    $status = Get-PlaybackStatus
    -not $status.playing -and $status.positionMs -ge 4500 -and $status.positionMs -le 5500
  }
  if (-not (Invoke-WinRtOperation $session.TryPlayAsync())) { throw 'GMTC play after seek was rejected.' }
  Wait-Until -Description 'GMTC play after seek to reach Navis' -Condition { (Get-PlaybackStatus).playing }
  if (-not (Invoke-WinRtOperation $session.TryChangeShuffleActiveAsync($true))) { throw 'GMTC shuffle command was rejected.' }
  Wait-Until -Description 'GMTC shuffle to reach Navis' -Condition { (Get-PlaybackStatus).shuffleMode -eq 'all' }
  $repeat = [Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType = WindowsRuntime]::List
  if (-not (Invoke-WinRtOperation $session.TryChangeAutoRepeatModeAsync($repeat))) { throw 'GMTC repeat command was rejected.' }
  Wait-Until -Description 'GMTC repeat to reach Navis' -Condition { (Get-PlaybackStatus).repeatMode -eq 'all' }

  Wait-ForPresentation
  Invoke-Api POST '/v1/presentation/screenshot' @{ label = 'windows-smtc' } |
    ConvertTo-Json | Set-Content (Join-Path $OutputRoot 'screenshot.json')
  Stop-Navis
  Start-Navis
  Wait-Until -Description 'restored queue after clean restart' -Condition { (Get-PlaybackStatus).songId -eq $SongId }
  $session = Wait-ForNavisSession
  if (-not (Invoke-WinRtOperation $session.TryPlayAsync())) { throw 'GMTC play after restart was rejected.' }
  Wait-Until -Description 'GMTC play after restart to reach Navis' -Condition { (Get-PlaybackStatus).playing }
  if (-not (Invoke-WinRtOperation $session.TryPauseAsync())) { throw 'GMTC pause after restart was rejected.' }
  Wait-Until -Description 'GMTC pause after restart to reach Navis' -Condition { -not (Get-PlaybackStatus).playing }
  Wait-ForPresentation
  Invoke-Api POST '/v1/presentation/screenshot' @{ label = 'windows-smtc-restart' } |
    ConvertTo-Json | Set-Content (Join-Path $OutputRoot 'restart-screenshot.json')
  $result = [ordered]@{
    status = 'passed'; target = 'windows'; profile = 'isolated-clone';
    appUserModelId = $session.SourceAppUserModelId; metadataPublished = $true;
    gmtcCommands = @('play', 'pause', 'next', 'previous', 'seek', 'shuffle', 'repeat');
    timelineProgressed = $true; pausedSeekVerified = $true; seekTargetMs = 5000; cleanRestart = $true; restartCommandsVerified = $true
  }
  $result | ConvertTo-Json | Set-Content (Join-Path $OutputRoot 'runtime-validation.json')
  Write-Host "Windows SMTC diagnostics passed: $OutputRoot"
} catch {
  try {
    Get-PlaybackStatus | Select-Object songId, playing, processingState, positionMs, playerPositionMs, durationMs, shuffleMode, repeatMode, navigation |
      ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputRoot 'failure-playback.json')
  } catch {}
  throw
} finally {
  Stop-Navis
  $script:Token = $null
}
