param(
  [string]$ConfigPath = "$env:LOCALAPPDATA\StoreLens\updater\config.json"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Log([string]$Message) {
  $root = Split-Path -Parent $ConfigPath
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
  Add-Content -Path (Join-Path $root "updater.log") -Value $line -Encoding UTF8
}

function Parse-Version([string]$Value) {
  try { return [version]$Value } catch { return [version]"0.0.0.0" }
}

try {
  if (-not (Test-Path $ConfigPath)) {
    throw "Updater config not found: $ConfigPath"
  }

  $config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
  $extensionPath = [string]$config.extensionPath
  $manifestUrl = [string]$config.manifestUrl

  if (-not $extensionPath -or -not (Test-Path $extensionPath)) {
    throw "Extension folder not found: $extensionPath"
  }
  if (-not $manifestUrl.StartsWith("https://")) {
    throw "Invalid update manifest URL"
  }

  $localManifestPath = Join-Path $extensionPath "manifest.json"
  if (-not (Test-Path $localManifestPath)) {
    throw "manifest.json not found in extension folder"
  }

  $localManifest = Get-Content -Raw -Path $localManifestPath | ConvertFrom-Json
  $localVersion = Parse-Version ([string]$localManifest.version)

  $remote = Invoke-RestMethod -Uri ($manifestUrl + "?_=" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Headers @{
    "Cache-Control" = "no-cache"
    "User-Agent" = "StoreLens-Updater"
  }

  if (-not $remote.version -or -not $remote.url -or -not $remote.sha256) {
    throw "Remote version.json is missing required fields"
  }

  $remoteVersion = Parse-Version ([string]$remote.version)
  if ($remoteVersion -le $localVersion) {
    Write-Log "No update. Local=$localVersion Remote=$remoteVersion"
    exit 0
  }

  Write-Log "Updating StoreLens $localVersion -> $remoteVersion"

  $tempRoot = Join-Path $env:TEMP ("StoreLensUpdate-" + [guid]::NewGuid().ToString("N"))
  $zipPath = Join-Path $tempRoot "storelens-extension.zip"
  $extractPath = Join-Path $tempRoot "extension"
  New-Item -ItemType Directory -Force -Path $extractPath | Out-Null

  try {
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$remote.url) -OutFile $zipPath -Headers @{
      "Cache-Control" = "no-cache"
      "User-Agent" = "StoreLens-Updater"
    }

    $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string]$remote.sha256).ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
      throw "SHA256 mismatch. Update package was not applied."
    }

    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $newManifestPath = Join-Path $extractPath "manifest.json"
    $newVersionPath = Join-Path $extractPath "version.json"
    if (-not (Test-Path $newManifestPath) -or -not (Test-Path $newVersionPath)) {
      throw "Downloaded package is invalid"
    }

    $newManifest = Get-Content -Raw -Path $newManifestPath | ConvertFrom-Json
    if ((Parse-Version ([string]$newManifest.version)) -ne $remoteVersion) {
      throw "Downloaded package version does not match update manifest"
    }

    foreach ($dir in @("background", "dashboard", "icons", "lib", "popup")) {
      $src = Join-Path $extractPath $dir
      $dst = Join-Path $extensionPath $dir
      if (Test-Path $src) {
        if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
        Copy-Item -Recurse -Force $src $dst
      }
    }

    Copy-Item -Force $newManifestPath (Join-Path $extensionPath "manifest.json")
    Copy-Item -Force $newVersionPath (Join-Path $extensionPath "version.json")

    $state = @{
      version = [string]$remote.version
      updatedAt = (Get-Date).ToString("o")
      sourceCommit = [string]$remote.sourceCommit
    } | ConvertTo-Json
    Set-Content -Path (Join-Path (Split-Path -Parent $ConfigPath) "last-update.json") -Value $state -Encoding UTF8

    Write-Log "Update installed successfully. The extension will reload itself shortly."
  }
  finally {
    if (Test-Path $tempRoot) {
      Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
    }
  }
}
catch {
  Write-Log ("ERROR: " + $_.Exception.Message)
  exit 1
}
