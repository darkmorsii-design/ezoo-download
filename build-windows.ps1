# Ezoo Download - one-click Windows build
# Installs what is missing (Visual Studio C++ Build Tools, Rust), builds
# EzooDownload.exe, gets ffmpeg + yt-dlp and makes dist\EzooDownload-Setup.exe.
#
# This builds the WINDOWS 7 compatible program (Rust target
# x86_64-win7-windows-msvc, see .cargo\config.toml). It also runs on
# Windows 8 / 10 / 11. Build on Windows 10/11 or Windows 7 SP1+ (64-bit).
#
# Optional parameters:
#   -UpdateRepo "owner/repo"   GitHub repository the finished program updates itself from
#                              (needed if you publish your own releases: the original ones
#                              are for Windows 10 and the program refuses them on Windows 7)
#   -FfmpegUrl  "https://...zip"  an ffmpeg zip that still runs on Windows 7
param(
    [string]$UpdateRepo = "",
    [string]$FfmpegUrl = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-7.0.1-essentials_build.zip"
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Fail($text) {
    Write-Host ""
    Write-Host "ERROR: $text" -ForegroundColor Red
    Write-Host "Send a screenshot of this window to Claude." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 1
}
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User") + ";" +
                "$env:USERPROFILE\.cargo\bin"
}

Write-Host "Ezoo Download build" -ForegroundColor Green
Write-Host "The first run downloads a few GB and can take 20-40 minutes. Later runs are fast."

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget was not found. Install 'App Installer' from the Microsoft Store, then run this again."
}

# ---------------------------------------------------------------- 1. C++ build tools
Step "Checking Visual Studio C++ Build Tools"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVc = $false
if (Test-Path $vswhere) {
    $vc = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vc) { $hasVc = $true }
}
if (-not $hasVc) {
    Step "Installing Visual Studio C++ Build Tools (big download, please wait; accept the admin prompt)"
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements `
        --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { Fail "Installing the C++ Build Tools failed (code $LASTEXITCODE)." }
} else {
    Write-Host "Found."
}

# ---------------------------------------------------------------- 2. Rust
Step "Checking Rust"
Refresh-Path
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Step "Installing Rust"
    winget install --id Rustlang.Rustup -e --accept-package-agreements --accept-source-agreements
    Refresh-Path
    if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { Fail "Rust was installed but not found. Restart the computer and run this again." }
}
# Windows 7 needs the nightly toolchain with the Rust sources: the standard
# library for the win7 target is compiled together with the program.
rustup toolchain install nightly --profile minimal --component rust-src
if ($LASTEXITCODE -ne 0) { Fail "Could not install the Rust nightly toolchain." }
rustup default nightly-x86_64-pc-windows-msvc | Out-Null
cargo --version

# the version comes from Cargo.toml ([workspace.package] version = "...")
$version = ([regex]::Match((Get-Content (Join-Path $PSScriptRoot "Cargo.toml") -Raw), '(?m)^version\s*=\s*"([^"]+)"')).Groups[1].Value
if (-not $version) { $version = "1.0.0" }
Write-Host "Version $version"

# ---------------------------------------------------------------- 3. build
# a running copy would lock the files we replace
Get-Process EzooDownload, SwiftGet -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Step "Building EzooDownload.exe for Windows 7 and newer (first time: 5-15 minutes)"
if ($UpdateRepo) { $env:EZOO_UPDATE_REPO = $UpdateRepo }
cargo win7
if ($LASTEXITCODE -ne 0) { Fail "The build failed. Scroll up to see the first red 'error' lines." }
$exePath = "target\x86_64-win7-windows-msvc\release\EzooDownload.exe"
if (-not (Test-Path $exePath)) { Fail "$exePath was not created." }

Step "Checking that EzooDownload.exe only uses functions Windows 7 has"
& (Join-Path $PSScriptRoot "tools\check-win7-imports.ps1") -Exe $exePath
if ($LASTEXITCODE -ne 0) { Fail "The program uses Windows functions that do not exist on Windows 7 (list above)." }

# ---------------------------------------------------------------- 4. package
# The result is ONE file: dist\EzooDownload-Setup.exe (+ dist\version.json
# for the GitHub release). Everything that goes into the setup is gathered
# first in build-cache\stage, which is not part of the result:
#   EzooDownload.exe, tools\yt-dlp.exe + ffmpeg.exe, extension, extension-firefox
Step "Preparing the files for the setup"
$dist = Join-Path $PSScriptRoot "dist"
$cache = Join-Path $PSScriptRoot "build-cache"
$stage = Join-Path $cache "stage"
$tools = Join-Path $stage "tools"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $dist, $stage, $tools, $cache | Out-Null
# what older builds left in dist: only the setup stays there
foreach ($old in @("EzooDownload.exe", "ffmpeg.exe", "yt-dlp.exe")) {
    Remove-Item (Join-Path $dist $old) -Force -ErrorAction SilentlyContinue
}
foreach ($old in @("extension", "portable", "store", "redist")) {
    if (Test-Path "$dist\$old") { Remove-Item -Recurse -Force "$dist\$old" }
}

Copy-Item $exePath $stage -Force
foreach ($name in @("extension", "extension-firefox")) {
    $to = Join-Path $stage $name
    if (Test-Path $to) { Remove-Item -Recurse -Force $to }
    Copy-Item -Recurse "extension" $to
    Remove-Item -Recurse -Force "$to\test" -ErrorAction SilentlyContinue
}
# Firefox wants its own manifest; the others ignore this file
Copy-Item -Force "$stage\extension-firefox\manifest.firefox.json" "$stage\extension-firefox\manifest.json"
Remove-Item "$stage\extension-firefox\manifest.firefox.json" -Force
Remove-Item "$stage\extension\manifest.firefox.json" -Force -ErrorAction SilentlyContinue

# ffmpeg (joins video + audio) and yt-dlp (finds video links): downloaded
# once into build-cache. On Windows 10/11 the app keeps both updated by itself;
# on Windows 7 / 8 it keeps exactly these two copies (the newest ffmpeg builds
# and the official yt-dlp.exe need Windows 10).
if (-not (Test-Path "$cache\ffmpeg.exe")) {
    Step "Downloading ffmpeg (joins video + audio) - a build that runs on Windows 7"
    try {
        $zip = Join-Path $env:TEMP "ezoo-ffmpeg.zip"
        $tmp = Join-Path $env:TEMP "ezoo-ffmpeg"
        Invoke-WebRequest $FfmpegUrl -OutFile $zip
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive $zip -DestinationPath $tmp
        $ff = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
        Copy-Item $ff.FullName $cache -Force
        $lic = Get-ChildItem $tmp -Recurse -Filter "LICENSE*" | Select-Object -First 1
        if ($lic) { Copy-Item $lic.FullName "$cache\ffmpeg-LICENSE.txt" -Force }
        Remove-Item -Recurse -Force $tmp, $zip
        # a version text that never equals the one of the newest Windows 10 build:
        # on Windows 10/11 the app then replaces this copy by the newest ffmpeg
        "windows7-build" | Set-Content "$cache\ffmpeg-version.txt" -NoNewline
    } catch {
        Write-Host "Could not download ffmpeg now ($FfmpegUrl)." -ForegroundColor Yellow
        Write-Host "Put a Windows 7 compatible ffmpeg.exe into $cache and run this again." -ForegroundColor Yellow
    }
}
if (-not (Test-Path "$cache\yt-dlp.exe")) {
    Step "Downloading yt-dlp (finds the links of videos) - the Windows 7 build"
    try {
        # the official yt-dlp.exe needs Windows 10; this community fork also publishes a Windows 7 build
        $rel = Invoke-RestMethod "https://api.github.com/repos/nicolaasjan/yt-dlp/releases/latest" -Headers @{ "User-Agent" = "EzooDownload-build" }
        $asset = $rel.assets | Where-Object { $_.name -match 'win7' -and $_.name -match '\.exe$' -and $_.name -notmatch 'x86' } | Select-Object -First 1
        if (-not $asset) { throw "the release has no x64 Windows 7 build" }
        Invoke-WebRequest $asset.browser_download_url -OutFile "$cache\yt-dlp.exe"
        "$($rel.tag_name) $($asset.name)" | Set-Content "$cache\yt-dlp-version.txt" -NoNewline
    } catch {
        Write-Host "Could not download the Windows 7 build of yt-dlp now ($_)." -ForegroundColor Yellow
        Write-Host "Put a Windows 7 compatible yt-dlp.exe into $cache and run this again." -ForegroundColor Yellow
    }
}
# Visual C++ runtime: the program already carries it (static CRT, see
# .cargo\config.toml). Optional: put Microsoft's vc_redist.x64.exe into
# build-cache yourself and the installer also installs it where it is missing.
$redist = Join-Path $cache "redist"
New-Item -ItemType Directory -Force $redist | Out-Null
if (Test-Path "$cache\vc_redist.x64.exe") { Copy-Item "$cache\vc_redist.x64.exe" $redist -Force }
Copy-Item "THIRD-PARTY-NOTICES.txt" $stage -Force
foreach ($f in @("ffmpeg.exe", "yt-dlp.exe", "ffmpeg-version.txt", "yt-dlp-version.txt", "ffmpeg-LICENSE.txt")) {
    if (Test-Path "$cache\$f") { Copy-Item "$cache\$f" $tools -Force }
}

# ---------------------------------------------------------------- 4b. signing (optional)
# With a code signing certificate antivirus programs and Windows SmartScreen
# trust the program. Put it in signing\ezoo.pfx and its password in
# signing\password.txt - everything is then signed automatically.
$pfx = Join-Path $PSScriptRoot "signing\ezoo.pfx"
$signtool = $null
if (Test-Path $pfx) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "x64" } | Select-Object -First 1 -ExpandProperty FullName
}
function Sign-File($file) {
    if (-not $signtool) { return }
    $pw = (Get-Content (Join-Path $PSScriptRoot "signing\password.txt") -Raw).Trim()
    & $signtool sign /fd SHA256 /f $pfx /p $pw /tr "http://timestamp.digicert.com" /td SHA256 /d "Ezoo Download" $file | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "Signed $file" } else { Write-Host "Could not sign $file" -ForegroundColor Yellow }
}
if ($signtool) {
    Step "Signing EzooDownload.exe"
    Sign-File "$stage\EzooDownload.exe"
}


# ---------------------------------------------------------------- 5. installer
Step "Creating the installer (EzooDownload-Setup.exe)"
function Find-Iscc {
    @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
      "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
      "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$iscc = Find-Iscc
if (-not $iscc) {
    Write-Host "Installing Inno Setup (makes the installer)..."
    winget install --id JRSoftware.InnoSetup -e --accept-package-agreements --accept-source-agreements | Out-Null
    $iscc = Find-Iscc
}
$setup = Join-Path $dist "EzooDownload-Setup.exe"
if ($iscc) {
    # Antivirus / OneDrive often lock a new .exe for a moment while Inno Setup
    # writes its icon into it ("EndUpdateResource failed"). So: build in a
    # temp folder, retry a few times, and as a last resort build without the
    # installer's own icon.
    $out = Join-Path $env:TEMP "ezoo-setup-build"
    New-Item -ItemType Directory -Force $out | Out-Null
    $iss = Join-Path $PSScriptRoot "installer\ezoo.iss"
    $ok = $false
    foreach ($extra in @("", "", "/DNoIcon")) {
        Remove-Item (Join-Path $out "EzooDownload-Setup.exe") -Force -ErrorAction SilentlyContinue
        $flags = @("/Q", "/O$out", "/DMyAppVersion=$version")
        if ($extra) { $flags += $extra }
        & $iscc @flags $iss
        if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $out "EzooDownload-Setup.exe"))) { $ok = $true; break }
        Write-Host "Retrying (the antivirus was probably scanning the file)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
    if ($ok) {
        Copy-Item (Join-Path $out "EzooDownload-Setup.exe") $setup -Force
        Sign-File $setup
        # version.json: the program reads it from the latest GitHub release
        # to update itself (version + SHA-256 of the installer)
        $hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLower()
        $json = "{`n  ""version"": ""$version"",`n  ""url"": ""https://github.com/AhmedEzo686/ezoo-download/releases/download/v$version/EzooDownload-Setup.exe"",`n  ""sha256"": ""$hash""`n}`n"
        [IO.File]::WriteAllText((Join-Path $dist "version.json"), $json)
    } else {
        Fail "Could not create the setup. Tip: move this folder out of Desktop/OneDrive (e.g. to C:\Ezoo) and run BUILD.bat again."
    }
} else {
    Fail "Inno Setup is not available, so the setup could not be made. Install Inno Setup 6 and run BUILD.bat again."
}

Write-Host ""
Write-Host "DONE!" -ForegroundColor Green
if (Test-Path $setup) {
    Write-Host ""
    Write-Host "  >> Double-click  dist\EzooDownload-Setup.exe  to install Ezoo Download <<" -ForegroundColor Green
    Write-Host "     (Start Menu folder, desktop shortcut, starts with Windows, uninstall from Settings > Apps)"
}
if (Test-Path "$dist\version.json") {
    Write-Host ""
    Write-Host "Also in $dist : version.json (it goes into the GitHub release together with the setup)"
}
Start-Process explorer.exe $dist
Read-Host "Press Enter to close"
