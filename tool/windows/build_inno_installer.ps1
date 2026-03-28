param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseDir,
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [Parameter(Mandatory = $true)]
  [string]$AssetPrefix,
  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ReleaseDir)) {
  throw "Windows release directory not found: $ReleaseDir"
}

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
  $candidatePaths = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
  )
  foreach ($candidate in $candidatePaths) {
    if (Test-Path -LiteralPath $candidate) {
      $iscc = @{ Source = $candidate }
      break
    }
  }
}

if (-not $iscc) {
  throw "Inno Setup compiler (ISCC.exe) not found. Install Inno Setup 6 and add ISCC.exe to PATH."
}

$semver = $Version.TrimStart('v')
$appName = if ($AssetPrefix -eq "navis-dev") { "Navis Dev" } else { "Navis" }
$defaultDir = if ($AssetPrefix -eq "navis-dev") { "{autopf}\Navis Dev" } else { "{autopf}\Navis" }
$appId = if ($AssetPrefix -eq "navis-dev") {
  "{{A1D6D40C-53A2-498B-BF0D-AEE8B0B8F7B7}}"
} else {
  "{{5803694E-7BB4-4E40-9262-D2CF7C2A9AF9}}"
}

$outputDir = [System.IO.Path]::GetDirectoryName($OutputPath)
$outputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$escapedReleaseDir = $ReleaseDir.Replace('\', '\\')
$escapedOutputDir = $outputDir.Replace('\', '\\')

$issBody = @"
#define MyAppName "$appName"
#define MyAppVersion "$semver"
#define MyAppPublisher "Khalifa"
#define MyAppExeName "navis.exe"
#define MySourceDir "$escapedReleaseDir"
#define MyOutputDir "$escapedOutputDir"
#define MyOutputBaseName "$outputBaseName"

[Setup]
AppId=$appId
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName=$defaultDir
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBaseName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
"@

$tempIssPath = Join-Path ([System.IO.Path]::GetTempPath()) ("navis-installer-{0}.iss" -f [Guid]::NewGuid().ToString("N"))
Set-Content -LiteralPath $tempIssPath -Value $issBody -Encoding UTF8

Write-Host "==> Building Windows installer with ISCC..."
& $iscc.Source $tempIssPath | Out-Host

if (-not (Test-Path -LiteralPath $OutputPath)) {
  throw "Installer was not generated at expected path: $OutputPath"
}

Write-Host "==> Windows installer ready: $OutputPath"

