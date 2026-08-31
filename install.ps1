#!/usr/bin/env pwsh
# Install fx from this fork's GitHub Releases.
#
#   irm https://github.com/keejkrej/fx/releases/latest/download/install.ps1 | iex
#
# Optional env:
#   FX_VERSION      Release tag without leading v (default: latest)
#   FX_REPO         GitHub repo (default: keejkrej/fx)
#   FX_INSTALL_DIR  Directory for the binary (default: %USERPROFILE%\.fx\bin)
#   FX_ARCHIVE      Local archive path (skip GitHub download)
#   FX_SKIP_PATH    Set to 1 to skip user PATH edits

$ErrorActionPreference = "Stop"

$Repo = if ($env:FX_REPO) { $env:FX_REPO } else { "keejkrej/fx" }
$InstallDir = if ($env:FX_INSTALL_DIR) {
    $env:FX_INSTALL_DIR
} else {
    Join-Path $env:USERPROFILE ".fx\bin"
}

function Get-ArchName {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch) {
        "AMD64" { return "x86_64" }
        "ARM64" { return "aarch64" }
        default { throw "unsupported architecture: $arch" }
    }
}

function Get-DownloadUrl([string]$Filename) {
    $version = $env:FX_VERSION
    if ([string]::IsNullOrWhiteSpace($version)) {
        return "https://github.com/$Repo/releases/latest/download/$Filename"
    }
    $tag = $version.TrimStart("v")
    return "https://github.com/$Repo/releases/download/v$tag/$Filename"
}

function Test-RemoteAsset([string]$Url) {
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = "HEAD"
        $request.AllowAutoRedirect = $true
        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
        $response.Close()
        return $status -ge 200 -and $status -lt 400
    } catch {
        return $false
    }
}

function Find-Payload([string]$Root, [string]$Name) {
    $match = Get-ChildItem -Path $Root -Recurse -File |
        Where-Object { $_.Name -eq $Name -or $_.Name -eq "$Name.exe" } |
        Select-Object -First 1
    if (-not $match) { throw "archive is missing $Name" }
    return $match.FullName
}

function Get-ExpectedChecksum([string]$Filename, [string]$Sums) {
    $line = ($Sums -split "`n") | Where-Object { $_ -match [regex]::Escape($Filename) } | Select-Object -First 1
    if (-not $line) {
        $line = ($Sums -split "`n") | Select-Object -First 1
    }
    if (-not $line) { return $null }
    return ($line -split "\s+")[0]
}

$nativeArch = Get-ArchName
$filename = "fx-windows-$nativeArch.zip"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("fx-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

try {
    if ($env:FX_ARCHIVE) {
        if (-not (Test-Path $env:FX_ARCHIVE)) { throw "FX_ARCHIVE not found: $($env:FX_ARCHIVE)" }
        $archive = $env:FX_ARCHIVE
        Write-Host "Installing from $archive"
    } else {
        $url = Get-DownloadUrl $filename
        if ($nativeArch -eq "aarch64" -and -not (Test-RemoteAsset $url)) {
            Write-Host "No native Windows ARM64 build published; using the x86_64 zip (emulation)."
            $filename = "fx-windows-x86_64.zip"
            $url = Get-DownloadUrl $filename
        }
        $archive = Join-Path $work $filename
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
        $verified = $false
        try {
            $sidecarUrl = Get-DownloadUrl "$filename.sha256"
            $sidecar = Invoke-WebRequest -Uri $sidecarUrl -UseBasicParsing
            $expected = Get-ExpectedChecksum $filename $sidecar.Content
            if ($expected) {
                $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
                if ($expected.ToLowerInvariant() -ne $actual) {
                    throw "checksum mismatch for $filename"
                }
                $verified = $true
            }
        } catch {
            if ($_.Exception.Message -match "checksum mismatch") { throw }
        }
        if (-not $verified) {
            try {
                $sumsUrl = Get-DownloadUrl "SHA256SUMS"
                $sums = Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing
                $expected = Get-ExpectedChecksum $filename $sums.Content
                if ($expected) {
                    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
                    if ($expected.ToLowerInvariant() -ne $actual) {
                        throw "checksum mismatch for $filename"
                    }
                }
            } catch {
                if ($_.Exception.Message -match "checksum mismatch") { throw }
                Write-Warning "Skipping checksum: $($_.Exception.Message)"
            }
        }
    }

    $unpacked = Join-Path $work "unpacked"
    Expand-Archive -Path $archive -DestinationPath $unpacked -Force
    $fxSrc = Find-Payload $unpacked "fx"
    Copy-Item $fxSrc (Join-Path $InstallDir (Split-Path $fxSrc -Leaf)) -Force
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($env:FX_SKIP_PATH -ne "1") {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    $parts = $userPath -split ";" | Where-Object { $_ }
    if ($parts -notcontains $InstallDir) {
        $newPath = if ($userPath.Trim().Length -eq 0) { $InstallDir } else { "$InstallDir;$userPath" }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$InstallDir;$env:Path"
        Write-Host "Added $InstallDir to your user PATH"
    }
}

Write-Host "Installed $(Join-Path $InstallDir 'fx.exe')"
Write-Host ""
Write-Host "Run:"
Write-Host "  fx"
