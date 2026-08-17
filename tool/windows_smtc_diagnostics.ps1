[CmdletBinding()]
param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [Parameter(Mandatory = $true)][string]$SourceDatabase,
  [Parameter(Mandatory = $true)][string]$CredentialFile,
  [Parameter(Mandatory = $true)][string]$SongId,
  [Parameter(Mandatory = $true)][string]$SecondSongId,
  [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "build\\windows-smtc-diagnostics\\$(Get-Date -Format 'yyyyMMddTHHmmssZ')-clone")
)

$ErrorActionPreference = 'Stop'
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
  param([Parameter(Mandatory = $true)][object]$Operation)
  $asyncInterface = $Operation.GetType().GetInterfaces() |
    Where-Object { $_.IsGenericType -and $_.GetGenericTypeDefinition().Name -eq 'IAsyncOperation`1' } |
    Select-Object -First 1
  if ($null -eq $asyncInterface) { throw "Unsupported WinRT operation type: $($Operation.GetType().FullName)" }
  $resultType = $asyncInterface.GetGenericArguments()[0]
  $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 } |
    Select-Object -First 1
  $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($Operation))
  return $task.GetAwaiter().GetResult()
}

function Get-NavisSession {
  $manager = Invoke-WinRtOperation ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync())
  return $manager.GetSessions() | Where-Object { $_.SourceAppUserModelId -eq $AppUserModelId } | Select-Object -First 1
}

function Wait-ForNavisSession {
  Wait-Until -Description 'the Navis GMTC session' -Condition { $null -ne (Get-NavisSession) }
  return Get-NavisSession
}

function Get-PlaybackStatus { return Invoke-Api GET '/v1/playback/status' }

function Stop-Navis {
  if ($null -eq $script:AppProcess) { return }
  try { Invoke-Api POST '/v1/shutdown' | Out-Null } catch {}
  if (-not $script:AppProcess.WaitForExit(30000)) { $script:AppProcess.Kill($true) }
  $script:AppProcess = $null
}

function Start-Navis {
  Remove-Item $Handshake -Force -ErrorAction SilentlyContinue
  $arguments = @(
    'run', '-d', 'windows', '--profile',
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
  $script:AppProcess = Start-Process -FilePath 'flutter' -ArgumentList $arguments -WorkingDirectory $RepoRoot -RedirectStandardOutput $AppLog -RedirectStandardError "$AppLog.stderr" -PassThru
  Wait-Until -Description 'the authenticated diagnostics API handshake' -TimeoutSeconds 180 -Condition { Test-Path $Handshake -PathType Leaf }
  $handshake = Get-Content -Raw $Handshake | ConvertFrom-Json
  $script:BaseUrl = "http://127.0.0.1:$($handshake.port)"
  $script:Token = $handshake.token
  Invoke-Api GET '/v1/health' | Out-Null
}

try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  Start-Navis
  Invoke-Api POST '/v1/playback/queue' @{ songIds = @($SongId, $SecondSongId) } | Out-Null
  Wait-Until -Description 'first queued song to play' -Condition { (Get-PlaybackStatus).songId -eq $SongId -and (Get-PlaybackStatus).playing }

  $session = Wait-ForNavisSession
  $media = Invoke-WinRtOperation $session.TryGetMediaPropertiesAsync()
  $playback = $session.GetPlaybackInfo()
  $timelineBefore = $session.GetTimelineProperties()
  if ([string]::IsNullOrWhiteSpace($media.Title) -or -not $playback.Controls.IsPauseEnabled -or -not $playback.Controls.IsNextEnabled -or -not $playback.Controls.IsPreviousEnabled) {
    throw 'GMTC metadata or transport capabilities were not published for active media.'
  }
  Start-Sleep -Seconds 2
  $timelineAfter = $session.GetTimelineProperties()
  if ($timelineAfter.Position -le $timelineBefore.Position) { throw 'GMTC timeline did not progress.' }

  if (-not (Invoke-WinRtOperation $session.TryPauseAsync())) { throw 'GMTC pause command was rejected.' }
  Wait-Until -Description 'GMTC pause to reach Navis' -Condition { -not (Get-PlaybackStatus).playing }
  if (-not (Invoke-WinRtOperation $session.TryPlayAsync())) { throw 'GMTC play command was rejected.' }
  Wait-Until -Description 'GMTC play to reach Navis' -Condition { (Get-PlaybackStatus).playing }
  if (-not (Invoke-WinRtOperation $session.TrySkipNextAsync())) { throw 'GMTC next command was rejected.' }
  Wait-Until -Description 'GMTC next to reach Navis' -Condition { (Get-PlaybackStatus).songId -eq $SecondSongId }
  if (-not (Invoke-WinRtOperation $session.TrySkipPreviousAsync())) { throw 'GMTC previous command was rejected.' }
  Wait-Until -Description 'GMTC previous to reach Navis' -Condition { (Get-PlaybackStatus).songId -eq $SongId }
  if (-not (Invoke-WinRtOperation $session.TryChangePlaybackPositionAsync([uint64]5000))) { throw 'GMTC seek command was rejected.' }
  Wait-Until -Description 'GMTC seek to reach Navis' -Condition { (Get-PlaybackStatus).positionMs -ge 4000 }
  if (-not (Invoke-WinRtOperation $session.TryChangeShuffleActiveAsync($true))) { throw 'GMTC shuffle command was rejected.' }
  Wait-Until -Description 'GMTC shuffle to reach Navis' -Condition { (Get-PlaybackStatus).shuffleMode -eq 'all' }
  $repeat = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionAutoRepeatMode]::List
  if (-not (Invoke-WinRtOperation $session.TryChangeAutoRepeatModeAsync($repeat))) { throw 'GMTC repeat command was rejected.' }
  Wait-Until -Description 'GMTC repeat to reach Navis' -Condition { (Get-PlaybackStatus).repeatMode -eq 'all' }

  Stop-Navis
  Start-Navis
  $session = Wait-ForNavisSession
  $result = [ordered]@{
    status = 'passed'; target = 'windows'; profile = 'isolated-clone';
    appUserModelId = $session.SourceAppUserModelId; metadataPublished = $true;
    gmtcCommands = @('play', 'pause', 'next', 'previous', 'seek', 'shuffle', 'repeat');
    timelineProgressed = $true; cleanRestart = $true
  }
  $result | ConvertTo-Json | Set-Content (Join-Path $OutputRoot 'runtime-validation.json')
  Write-Host "Windows SMTC diagnostics passed: $OutputRoot"
} finally {
  Stop-Navis
  $script:Token = $null
}
