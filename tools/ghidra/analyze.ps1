# Ghidra headless driver for the CarWithin binary.
# ASCII only: Windows PowerShell 5.1 reads .ps1 as ANSI, so non-ASCII breaks parsing.
#
#   .\tools\ghidra\analyze.ps1 -Mode import
#   .\tools\ghidra\analyze.ps1 -Mode process -Out analysis\decompiled-about.c -Filters aboutLinks
param(
    [ValidateSet("import", "process")]
    [string]$Mode = "import",
    [string]$Binary = "C:\Users\xaehd\WorkBuddy\2026-11-22-00-22-51\carwithin-analysis\ipa\Payload\TDSCarKit.app\TDSCarKit",
    [string]$Out = "analysis\decompiled-settings.c",
    [string[]]$Filters = @("aboutLinks", "SettingsRow", "SettingsPageController", "SettingsSection")
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Find-Ghidra {
    if ($env:GHIDRA_HOME -and (Test-Path (Join-Path $env:GHIDRA_HOME "support\analyzeHeadless.bat"))) {
        return $env:GHIDRA_HOME
    }
    $candidates = Get-ChildItem "D:\tools" -Directory -Filter "ghidra_*_PUBLIC" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c.FullName "support\analyzeHeadless.bat")) { return $c.FullName }
    }
    throw "Ghidra not found under D:\tools or GHIDRA_HOME"
}

function Find-Jdk {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        return $env:JAVA_HOME
    }
    $candidates = Get-ChildItem "D:\tools" -Directory -Filter "jdk-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c.FullName "bin\java.exe")) { return $c.FullName }
    }
    $fallback = "C:\Program Files\Java\jdk-17"
    if (Test-Path (Join-Path $fallback "bin\java.exe")) { return $fallback }
    throw "JDK not found under D:\tools or JAVA_HOME"
}

$ghidra = Find-Ghidra
$jdk = Find-Jdk
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;" + $env:PATH

$headless = Join-Path $ghidra "support\analyzeHeadless.bat"
$projDir = Join-Path $repo "analysis\ghidra-project"
New-Item -ItemType Directory -Force -Path $projDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $repo $Out)) | Out-Null

$outPath = Join-Path $repo $Out

$headlessArgs = @(
    $projDir, "CarWithin",
    $(if ($Mode -eq "import") { "-import" } else { "-process" }), $Binary,
    "-scriptPath", $PSScriptRoot,
    "-postScript", "DecompileByName.java", $outPath
) + $Filters
if ($Mode -eq "process") { $headlessArgs += "-noanalysis" }

Write-Host "Ghidra: $ghidra"
Write-Host "JDK:    $jdk"
Write-Host "Mode:   $Mode"
Write-Host "Out:    $outPath"
Write-Host "Filter: $($Filters -join ', ')"

& $headless @headlessArgs
if ($LASTEXITCODE -ne 0) { throw "analyzeHeadless exit code $LASTEXITCODE" }
Write-Host "Done: $outPath"
