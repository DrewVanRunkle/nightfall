#Requires -Version 5.1
<#
.SYNOPSIS
    Windows build/export script for Nightfall. PowerShell equivalent of build.sh.

.DESCRIPTION
    build.sh is bash and assumes a Linux layout, so it cannot run natively on
    Windows (Git Bash lacks `unzip`, and the tool paths differ). This script
    mirrors what build.sh does for the Android export path only:

      1. Extract the Godot Android source template into android/build
      2. Overlay the patched libgodot_android.so (AHB Vulkan patch), if present
      3. Copy GodotApp.java / DepthEstimator.java and the TFLite assets
      4. Inject the tensorflow-lite Gradle dependency
      5. Stage the correct GodotOpenXRVendors AAR for the target vendor
      6. Export the APK via Godot headless
      7. Clean up android/build, optionally adb install

    The Linux/AppImage paths in build.sh are NOT reproduced here.

    No developer-specific paths are hardcoded. Every tool location resolves from
    an environment variable, falling back to a conventional Windows default.

.PARAMETER Target
    quest     -> NightfallDev / NightfallRelease preset, stages the Meta AAR.
    androidxr -> NightfallAndroidXR preset, stages the Android XR AAR.

.PARAMETER Release
    Export the release build instead of debug. Requires keystore values (see .env).

.PARAMETER Install
    Run `adb install -r` on the resulting APK.

.EXAMPLE
    .\build.ps1 -Target androidxr -Install
.EXAMPLE
    .\build.ps1 -Target quest -Release
#>
[CmdletBinding()]
param(
    [ValidateSet('quest', 'androidxr')]
    [string]$Target = 'androidxr',

    [switch]$Release,
    [switch]$Install,

    # Override if your Godot version differs. Must match the installed
    # export templates directory name exactly.
    [string]$GodotVersion = '4.7.1.stable',

    # Preset names as they appear in export_presets.cfg.
    [string]$QuestDebugPreset   = 'NightfallDev',
    [string]$QuestReleasePreset = 'NightfallRelease',
    [string]$AndroidXRPreset    = 'NightfallAndroidXR'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $ScriptDir

# --------------------------------------------------------------------------
# Tool resolution. Env var first, then a conventional default. Nothing here
# should ever be a path specific to one developer's machine.
# --------------------------------------------------------------------------

function Resolve-Tool {
    param(
        [string]$EnvVarName,
        [string[]]$Candidates,
        [string]$Description,
        [string]$Hint
    )
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvVarName)
    if ($fromEnv) {
        if (Test-Path $fromEnv) { return (Resolve-Path $fromEnv).Path }
        throw "$EnvVarName is set to '$fromEnv' but that path does not exist."
    }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    throw @"
Could not locate $Description.
Set the $EnvVarName environment variable, e.g.:
    `$env:$EnvVarName = "$Hint"
"@
}

# Prefer the _console.exe build: on Windows the plain .exe detaches from the
# console, so a headless export prints nothing and failures are invisible.
$Godot = Resolve-Tool -EnvVarName 'GODOT_BIN' -Description 'the Godot editor binary' `
    -Hint 'C:\Godot\Godot_v4.7.1-stable_win64_console.exe' `
    -Candidates @(
        "C:\Godot\Godot_v$GodotVersion`_win64_console.exe",
        "C:\Godot\Godot_v$($GodotVersion -replace '\.stable$')-stable_win64_console.exe",
        "C:\Godot\Godot_v4.7.1-stable_win64_console.exe",
        "C:\Godot\Godot_v4.7.1-stable_win64.exe"
    )

if ($Godot -notmatch '_console\.exe$') {
    Write-Warning "Using '$([IO.Path]::GetFileName($Godot))' - not the _console build. If the export fails silently, point GODOT_BIN at Godot_v${GodotVersion}_win64_console.exe instead."
}

$Templates = Resolve-Tool -EnvVarName 'GODOT_ANDROID_TEMPLATE' -Description 'android_source.zip (Godot export templates)' `
    -Hint "$env:APPDATA\Godot\export_templates\$GodotVersion\android_source.zip" `
    -Candidates @("$env:APPDATA\Godot\export_templates\$GodotVersion\android_source.zip")

$JavaHome = Resolve-Tool -EnvVarName 'JAVA_HOME_17' -Description 'a JDK 17 installation' `
    -Hint 'C:\Program Files\Eclipse Adoptium\jdk-17.0.13-hotspot' `
    -Candidates @(
        (Get-ChildItem 'C:\Program Files\Eclipse Adoptium\jdk-17*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem 'C:\Program Files\Microsoft\jdk-17*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem 'C:\Program Files\Java\jdk-17*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName)
    )

# --------------------------------------------------------------------------
# Target selection: preset name, vendor AAR, output filename.
# The vendor AAR must match whichever enable_*_plugin the preset turns on.
# --------------------------------------------------------------------------

$buildType = if ($Release) { 'release' } else { 'debug' }

switch ($Target) {
    'androidxr' {
        $Preset     = $AndroidXRPreset
        $VendorAar  = "godotopenxr-androidxr-$buildType.aar"
        $Output     = if ($Release) { 'Nightfall-AndroidXR-arm64-v8a.apk' }
                      else          { 'Nightfall-AndroidXR-arm64-v8a-debug.apk' }
    }
    'quest' {
        $Preset     = if ($Release) { $QuestReleasePreset } else { $QuestDebugPreset }
        $VendorAar  = "godotopenxr-meta-$buildType.aar"
        $Output     = if ($Release) { 'Nightfall-Android-arm64-v8a.apk' }
                      else          { 'Nightfall-Android-arm64-v8a-debug.apk' }
    }
}

Write-Host "=== Nightfall build ===" -ForegroundColor Cyan
Write-Host "  Target   : $Target ($buildType)"
Write-Host "  Preset   : $Preset"
Write-Host "  Vendor   : $VendorAar"
Write-Host "  Godot    : $Godot"
Write-Host "  JDK 17   : $JavaHome"
Write-Host "  Output   : $Output"
Write-Host ""

$ConfigPath   = Join-Path $ScriptDir 'export_presets.cfg'
$ConfigBackup = "$ConfigPath.bak"

# Verify the preset actually exists before doing any expensive work.
if (-not (Select-String -Path $ConfigPath -Pattern "^name=`"$Preset`"$" -Quiet)) {
    # Enumerate every match's capture group individually - flattening .Matches
    # and then indexing .Groups[1] silently yields only the first preset name.
    $available = Select-String -Path $ConfigPath -Pattern '^name="(.+)"$' |
                 ForEach-Object { $_.Matches[0].Groups[1].Value }
    throw "Preset '$Preset' not found in export_presets.cfg. Available: " +
          ($available -join ', ') +
          "`nIf 'NightfallAndroidXR' is missing, pull the latest commits on this branch."
}

try {
    # ----------------------------------------------------------------------
    # Release keystore substitution (mirrors build.sh:138-155).
    # export_presets.cfg stores ${NIGHTFALL_KEYSTORE_*} placeholders; real
    # credentials come from .env and are swapped in only for the export, then
    # reverted in the finally block so they never end up committed.
    # ----------------------------------------------------------------------
    if ($Release -and $Target -eq 'quest') {
        $envFile = Join-Path $ScriptDir '.env'
        if (-not (Test-Path $envFile)) {
            throw ".env not found. Copy .env.example and fill in keystore credentials."
        }
        $envVars = @{}
        Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$' } | ForEach-Object {
            if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$') { $envVars[$Matches[1]] = $Matches[2].Trim('"') }
        }
        foreach ($k in 'NIGHTFALL_KEYSTORE_PATH', 'NIGHTFALL_KEYSTORE_USER', 'NIGHTFALL_KEYSTORE_PASSWORD') {
            if (-not $envVars.ContainsKey($k) -or -not $envVars[$k]) { throw ".env missing $k" }
        }
        Copy-Item $ConfigPath $ConfigBackup -Force
        (Get-Content $ConfigPath -Raw).
            Replace('${NIGHTFALL_KEYSTORE_PATH}',     $envVars['NIGHTFALL_KEYSTORE_PATH']).
            Replace('${NIGHTFALL_KEYSTORE_USER}',     $envVars['NIGHTFALL_KEYSTORE_USER']).
            Replace('${NIGHTFALL_KEYSTORE_PASSWORD}', $envVars['NIGHTFALL_KEYSTORE_PASSWORD']) |
            Set-Content $ConfigPath -NoNewline
        Write-Host "Patched keystore credentials into export_presets.cfg"
    }

    # ----------------------------------------------------------------------
    # Stage the Gradle project (mirrors build.sh:165-188).
    # ----------------------------------------------------------------------
    $buildDir = Join-Path $ScriptDir 'android\build'
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

    Write-Host "Extracting Android template..."
    Expand-Archive -Path $Templates -DestinationPath $buildDir -Force

    # Patched Godot engine .so (AHB Vulkan patch). Optional: without it the app
    # still builds and launches, but every decoded video frame is dropped at
    # stream_connection.cpp:1195 and the screen stays black.
    $patchedSo = Join-Path $ScriptDir 'addons\nightfall-stream\bin\android\libgodot_android.so'
    if (Test-Path $patchedSo) {
        foreach ($dest in @(
            'aar_extract\jni\arm64-v8a',
            'libs\release\arm64-v8a',
            'libs\debug\arm64-v8a'
        )) {
            $full = Join-Path $buildDir $dest
            New-Item -ItemType Directory -Path $full -Force | Out-Null
            Copy-Item $patchedSo (Join-Path $full 'libgodot_android.so') -Force
        }
        Write-Host "Overlaid patched libgodot_android.so (AHB video path enabled)"
    } else {
        Write-Warning "addons\nightfall-stream\bin\android\libgodot_android.so not found."
        Write-Warning "  Building against the STOCK engine: app will launch but video stays BLACK."
        Write-Warning "  logcat will show 'SKIP: ... has=0' from VCONN. See ANDROID_XR_PORT.md section 6."
    }

    # Java sources
    $javaDest = Join-Path $buildDir 'src\main\java\com\godot\game'
    New-Item -ItemType Directory -Path $javaDest -Force | Out-Null
    foreach ($j in 'GodotApp.java', 'DepthEstimator.java') {
        Copy-Item (Join-Path $ScriptDir "android\src\main\java\com\godot\game\$j") $javaDest -Force
    }

    # TFLite assets: MiDaS is committed, Depth-Anything-V2 is generated separately.
    $assetDest = Join-Path $buildDir 'src\main\assets'
    New-Item -ItemType Directory -Path $assetDest -Force | Out-Null
    Copy-Item (Join-Path $ScriptDir 'android\src\main\assets\midas-midas-v2-w8a8.tflite') $assetDest -Force
    $dav2 = Join-Path $ScriptDir 'android\src\main\assets\depth-anything-v2-small.tflite'
    if (Test-Path $dav2) { Copy-Item $dav2 $assetDest -Force }

    # Inject the tensorflow-lite dependency (mirrors build.sh:181).
    $gradleFile = Join-Path $buildDir 'build.gradle'
    $lines = Get-Content $gradleFile
    $patched = $false
    $newLines = foreach ($line in $lines) {
        $line
        if (-not $patched -and $line -match 'implementation\s+"androidx\.documentfile:documentfile') {
            ''
            '    implementation "org.tensorflow:tensorflow-lite:2.16.1"'
            $patched = $true
        }
    }
    if (-not $patched) {
        throw "Could not find the androidx.documentfile anchor line in build.gradle. The Godot template layout changed; update this script's injection point."
    }
    Set-Content $gradleFile $newLines
    Write-Host "Injected tensorflow-lite:2.16.1 dependency"

    # Stage the vendor AAR matching this preset's enabled vendor plugin.
    $aarSrc = Join-Path $ScriptDir "addons\godotopenxrvendors\.bin\android\$buildType\$VendorAar"
    if (-not (Test-Path $aarSrc)) {
        throw @"
Vendor AAR not found: $aarSrc
Install the GodotOpenXRVendors plugin (v5.1+) via the in-editor AssetLib.
"@
    }
    $aarDest = Join-Path $buildDir "libs\$buildType"
    New-Item -ItemType Directory -Path $aarDest -Force | Out-Null
    Copy-Item $aarSrc $aarDest -Force
    Write-Host "Staged $VendorAar"

    # ----------------------------------------------------------------------
    # Export.
    # ----------------------------------------------------------------------
    $exportFlag = if ($Release) { '--export-release' } else { '--export-debug' }
    $outPath    = Join-Path $ScriptDir $Output
    if (Test-Path $outPath) { Remove-Item $outPath -Force }

    Write-Host "`nExporting $Preset..." -ForegroundColor Cyan
    $env:JAVA_HOME = $JavaHome
    & $Godot --headless --path $ScriptDir $exportFlag $Preset $outPath
    $exportExit = $LASTEXITCODE

    if (-not (Test-Path $outPath)) {
        throw "Export failed (godot exit code $exportExit): $Output was not created."
    }

    $sizeMb = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
    Write-Host "`nExported $Output ($sizeMb MB)" -ForegroundColor Green
}
finally {
    # Always restore the un-substituted export_presets.cfg so keystore
    # credentials cannot be accidentally committed.
    if (Test-Path $ConfigBackup) {
        Move-Item $ConfigBackup $ConfigPath -Force
        Write-Host "Restored original export_presets.cfg"
    }
    # Godot rescans android/build and errors on stale artifacts; build.sh
    # removes it after every export for the same reason (build.sh:207).
    $buildDir = Join-Path $ScriptDir 'android\build'
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
    $strayActionMap = Join-Path $ScriptDir 'openxr_action_map.tres'
    if (Test-Path $strayActionMap) { Remove-Item $strayActionMap -Force -ErrorAction SilentlyContinue }
    Pop-Location
}

if ($Install) {
    Write-Host "`nInstalling on device..." -ForegroundColor Cyan
    & adb install -r (Join-Path $ScriptDir $Output)
    if ($LASTEXITCODE -ne 0) { throw "adb install failed (exit $LASTEXITCODE)" }
    Write-Host "Done." -ForegroundColor Green
}
