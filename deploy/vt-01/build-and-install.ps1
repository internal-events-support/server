# Builds the latest CasparCG Server release with NDI sent as BGRX (no alpha) by default,
# plus an <alpha>true</alpha> setting to send BGRA on individual NDI outputs.
# Installs it to Documents\CasparCG and points Windows startup at it.
# Your config, media, templates and data are kept when you re-run this.
# -StopRunning stops a running Documents copy at install time without asking.

param([switch]$StopRunning)

$ErrorActionPreference = 'Stop'

$here       = $PSScriptRoot
$installDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CasparCG'
$serverDir  = Join-Path $installDir 'Server'
$clientDir  = Join-Path $installDir 'Client'
$workRoot   = Join-Path $env:LOCALAPPDATA 'CasparCG-Build'
$startupDir = [Environment]::GetFolderPath('Startup')
$downloads  = Join-Path $env:USERPROFILE 'Downloads'
$oldServer  = Join-Path $downloads 'casparcg-server-v2.5.1-windows'
$oldClient  = Join-Path $downloads 'casparcg-client-v2.3.1-windows\casparcg_client\casparcg_client'
$vcvars     = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'
$sevenZip   = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
$gitExe     = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
$patchFile  = 'src\modules\newtek\consumer\newtek_ndi_consumer.cpp'

function Step($text) { Write-Host ''; Write-Host "=== $text ===" -ForegroundColor Cyan }

function Copy-Tree($from, $to, $extra = @()) {
    $options = @('/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') + $extra
    & robocopy $from $to @options | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed ($LASTEXITCODE): $from -> $to" }
    $global:LASTEXITCODE = 0
}

function Seed-Folder($name) {
    $target = Join-Path $serverDir $name
    $source = Join-Path $oldServer $name
    $empty  = -not (Test-Path $target) -or -not (Get-ChildItem $target -Force | Select-Object -First 1)
    if ($empty -and (Test-Path $source)) {
        Write-Host "Copying $name from the Downloads install..."
        Copy-Tree $source $target
    }
}

# --- Prerequisites ----------------------------------------------------------
Step 'Checking build tools'
$missing = @()
if (-not (Test-Path $vcvars))   { $missing += 'Visual Studio 2022 Community (C++ workload, about 10 GB)' }
if (-not (Test-Path $gitExe))   { $missing += 'Git' }
if (-not (Test-Path $sevenZip)) { $missing += '7-Zip' }

if ($missing) {
    Write-Host 'These need installing with winget:'
    $missing | ForEach-Object { Write-Host "  - $_" }
    Write-Host 'winget will ask you to accept their license terms. Windows may also ask for permission.'
    if ((Read-Host 'Install them now? (Y/N)') -notmatch '^[Yy]') { throw 'Cancelled: build tools are required.' }

    if (-not (Test-Path $gitExe))   { winget install --id Git.Git -e --source winget }
    if (-not (Test-Path $sevenZip)) { winget install --id 7zip.7zip -e --source winget }
    if (-not (Test-Path $vcvars)) {
        winget install --id Microsoft.VisualStudio.2022.Community -e --source winget `
            --override '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended'
    }

    if (-not (Test-Path $vcvars))   { throw "Visual Studio C++ tools not found. If VS 2022 is already installed, add 'Desktop development with C++' in the Visual Studio Installer. Expected: $vcvars" }
    if (-not (Test-Path $gitExe))   { throw 'Git did not install.' }
    if (-not (Test-Path $sevenZip)) { throw '7-Zip did not install.' }
}
$env:Path = "$(Split-Path $gitExe);$env:Path"

# --- Source -----------------------------------------------------------------
Step 'Finding the latest release'
$tag = (Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/CasparCG/server/releases/latest').tag_name
if (-not $tag) { throw 'Could not read the latest release from GitHub.' }
Write-Host "Latest release: $tag"

$src = Join-Path $workRoot $tag
if (Test-Path $src) { Remove-Item $src -Recurse -Force }
New-Item -ItemType Directory -Force $workRoot | Out-Null

Step "Downloading source for $tag"
& $gitExe clone --depth 1 --recurse-submodules --branch $tag 'https://github.com/CasparCG/server' $src
if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }

# --- Patch ------------------------------------------------------------------
Step 'Applying NDI alpha patch'
$file  = Join-Path $src $patchFile
$text  = [IO.File]::ReadAllText($file)
$edits = @(
    @{ Count = 1; Old = 'const bool              allow_fields_;'
       New = "const bool              allow_fields_;`n    const bool              alpha_;" },
    @{ Count = 1; Old = 'newtek_ndi_consumer(std::wstring name, bool allow_fields)'
       New = 'newtek_ndi_consumer(std::wstring name, bool allow_fields, bool alpha)' },
    @{ Count = 1; Old = ', allow_fields_(allow_fields)'
       New = ", allow_fields_(allow_fields)`n        , alpha_(alpha)" },
    @{ Count = 1; Old = 'ndi_video_frame_.FourCC               = NDIlib_FourCC_type_BGRA;'
       New = 'ndi_video_frame_.FourCC               = alpha_ ? NDIlib_FourCC_type_BGRA : NDIlib_FourCC_type_BGRX;' },
    @{ Count = 1; Old = 'bool         allow_fields = contains_param(L"ALLOW_FIELDS", params);'
       New = "bool         allow_fields = contains_param(L`"ALLOW_FIELDS`", params);`n    bool         alpha        = contains_param(L`"ALPHA`", params);" },
    @{ Count = 1; Old = 'bool allow_fields = ptree.get(L"allow-fields", false);'
       New = "bool allow_fields = ptree.get(L`"allow-fields`", false);`n    bool alpha        = ptree.get(L`"alpha`", false);" },
    @{ Count = 2; Old = 'spl::make_shared<newtek_ndi_consumer>(name, allow_fields)'
       New = 'spl::make_shared<newtek_ndi_consumer>(name, allow_fields, alpha)' }
)
foreach ($edit in $edits) {
    $found = [regex]::Matches($text, [regex]::Escape($edit.Old)).Count
    if ($found -ne $edit.Count) { throw "Expected $($edit.Count) of '$($edit.Old)' in $patchFile but found $found. This release has changed, so the patch needs updating." }
    $text = $text.Replace($edit.Old, $edit.New)
}
[IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $false))
Write-Host 'NDI outputs now send BGRX, or BGRA where <alpha>true</alpha> is set.'

# --- Build ------------------------------------------------------------------
Step 'Building (this can take a long time and will use a lot of CPU)'
$log = Join-Path $workRoot "build-$tag.log"
Push-Location $src
try {
    cmd /c "tools\windows\build.bat 2>&1" | Tee-Object -FilePath $log
    $buildExit = $LASTEXITCODE
} finally { Pop-Location }

$built = Join-Path $src 'dist\casparcg_server'
if ($buildExit -ne 0 -or -not (Test-Path (Join-Path $built 'casparcg.exe'))) {
    throw "Build failed (exit code $buildExit). Log: $log"
}

# --- Install ----------------------------------------------------------------
Step "Installing to $installDir"
$running = Get-Process casparcg -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$serverDir*" }
if ($running) {
    Write-Host 'The Documents copy of CasparCG is running. Installing will stop it and interrupt any output.'
    if (-not $StopRunning -and (Read-Host 'Stop it and continue? (Y/N)') -notmatch '^[Yy]') { throw "Cancelled. The finished build is still at $built" }
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
}

New-Item -ItemType Directory -Force $serverDir, $clientDir | Out-Null
Copy-Tree $built $serverDir @('/XF', 'casparcg.config')

$config = Join-Path $serverDir 'casparcg.config'
if (-not (Test-Path $config)) {
    $oldConfig = Join-Path $oldServer 'casparcg.config'
    $newConfig = Join-Path $built 'casparcg.config'
    if (Test-Path $oldConfig)     { Copy-Item $oldConfig $config }
    elseif (Test-Path $newConfig) { Copy-Item $newConfig $config }
    else { throw "No casparcg.config found to install at $config" }
}
foreach ($name in 'media', 'template', 'data') { Seed-Folder $name }

# The scanner and client are separate projects and are not part of the server build.
if (-not (Get-ChildItem $serverDir -Filter 'casparcg-scanner-*.exe')) {
    $scanner = Get-ChildItem $oldServer -Filter 'casparcg-scanner-*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $scanner) { throw "Media scanner not found in $oldServer" }
    Copy-Item $scanner.FullName $serverDir
}
if (-not (Test-Path (Join-Path $clientDir 'casparcg-client.exe'))) {
    if (-not (Test-Path (Join-Path $oldClient 'casparcg-client.exe'))) { throw "Client not found in $oldClient" }
    Copy-Tree $oldClient $clientDir
}

Copy-Item (Join-Path $here 'start-all.bat') $installDir -Force
Set-Content -Path (Join-Path $installDir 'INSTALLED.txt') -Encoding ascii -Value @(
    "Release: $tag", "Built: $(Get-Date -Format 'yyyy-MM-dd HH:mm')", 'Patch: NDI outputs send BGRX, or BGRA where <alpha>true</alpha> is set')

# --- Startup ----------------------------------------------------------------
Step 'Updating Windows startup'
$backup = Join-Path $here 'old-startup-shortcuts'
Get-ChildItem $startupDir -Filter 'casparcg*.lnk' | Where-Object { $_.Name -ne 'CasparCG.lnk' } | ForEach-Object {
    New-Item -ItemType Directory -Force $backup | Out-Null
    Move-Item $_.FullName $backup -Force
    Write-Host "Moved old shortcut to old-startup-shortcuts: $($_.Name)"
}
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startupDir 'CasparCG.lnk'))
$shortcut.TargetPath       = Join-Path $installDir 'start-all.bat'
$shortcut.Arguments        = 'boot'
$shortcut.WorkingDirectory = $installDir
$shortcut.Save()

Step 'Done'
Write-Host "Installed $tag with the NDI alpha patch to $installDir" -ForegroundColor Green
Write-Host 'Nothing has been restarted. To switch over, run "Restart CasparCG.bat" on the desktop.'
