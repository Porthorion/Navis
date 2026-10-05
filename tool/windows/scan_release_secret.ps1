param(
  [Parameter(Mandatory = $true)][string]$ReleaseDir,
  [Parameter(Mandatory = $true)][string]$DefinesPath
)
$ErrorActionPreference = 'Stop'
# Recover only in memory; never put the key on argv, in a log or on disk.
$defines = Get-Content -LiteralPath $DefinesPath -Raw | ConvertFrom-Json
$masked = $defines.NAVIS_LASTFM_API_KEY_MASKED
$pad = $defines.NAVIS_LASTFM_API_KEY_PAD
if (-not $masked -or $masked.Length -ne $pad.Length -or $masked.Length % 2 -ne 0) {
  throw 'Invalid Last.fm masking input; refusing an unscanned release'
}
[byte[]]$secretBytes = for ($i = 0; $i -lt $masked.Length; $i += 2) {
  [Convert]::ToByte($masked.Substring($i, 2), 16) -bxor [Convert]::ToByte($pad.Substring($i, 2), 16)
}
if (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
  throw 'Windows release directory missing'
}
# Latin1 preserves every binary byte, including NUL, for an ordinal search.
$encoding = [Text.Encoding]::GetEncoding(28591)
$secret = $encoding.GetString($secretBytes)
Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File -Force -ErrorAction Stop | ForEach-Object {
  $contents = $encoding.GetString([IO.File]::ReadAllBytes($_.FullName))
  if ($contents.IndexOf($secret, [StringComparison]::Ordinal) -ge 0) {
    throw 'Plaintext Last.fm key found in Windows release payload'
  }
}
