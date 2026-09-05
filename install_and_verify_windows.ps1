param(
  [switch]$Install,
  [switch]$Launch,
  [string]$InstallDir = "$env:LOCALAPPDATA\Programs\sepsiscare"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallerDir = Join-Path $Root "02_installers\windows"
$Installer = Get-ChildItem -Path $InstallerDir -Filter "sepsiscare-*-win-x64.exe" -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1

function Write-Ok($Message) {
  Write-Host "ok: $Message"
}

function Test-Manifest {
  $Manifest = Join-Path $Root "SHA256SUMS.txt"
  if (!(Test-Path $Manifest)) { throw "Missing SHA256SUMS.txt" }
  $Count = 0
  Get-Content $Manifest | ForEach-Object {
    if ($_ -match "^([a-fA-F0-9]{64})\s+\./(.+)$") {
      $Expected = $Matches[1].ToLowerInvariant()
      $Relative = $Matches[2] -replace "/", "\"
      $Path = Join-Path $Root $Relative
      if (!(Test-Path $Path)) { throw "Missing manifest file: $Relative" }
      $Actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
      if ($Actual -ne $Expected) { throw "SHA256 mismatch: $Relative" }
      $Count += 1
    }
  }
  Write-Ok "SHA256 manifest verified ($Count files)"
}

Write-Host "SepsisCare Windows delivery verification"
Write-Host "Root: $Root"

Test-Manifest

if (!$Installer) { throw "Windows installer was not found in $InstallerDir" }
Write-Ok "Windows installer found: $($Installer.FullName)"
Write-Ok "Installer size: $([math]::Round($Installer.Length / 1MB, 1)) MB"

if ($Install) {
  Write-Host "Installing silently..."
  $Arguments = "/S"
  if ($InstallDir) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $Arguments = "/S /D=$InstallDir"
  }
  $Process = Start-Process -FilePath $Installer.FullName -ArgumentList $Arguments -Wait -PassThru
  if ($Process.ExitCode -ne 0) { throw "Installer failed with exit code $($Process.ExitCode)" }
  Write-Ok "Installer completed"
}

$InstalledExe = Join-Path $InstallDir "sepsiscare.exe"
if (Test-Path $InstalledExe) {
  Write-Ok "Installed app executable found: $InstalledExe"
  if ($Launch) {
    Start-Process -FilePath $InstalledExe
    Write-Ok "Launched SepsisCare"
  }
} else {
  Write-Host "Install check skipped: $InstalledExe not found. Run with -Install to install silently, or double-click the installer."
}

Write-Ok "Windows delivery verification completed"
