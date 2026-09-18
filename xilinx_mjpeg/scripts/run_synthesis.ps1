param(
    [Parameter(Mandatory=$true)][string]$Part,
    [ValidateRange(1,4)][int]$Channels = 2,
    [ValidateRange(16,1920)][int]$MaxWidth = 1920,
    [ValidateRange(1.0,1000.0)][double]$PeriodNs = 5.0,
    [string]$VivadoRoot = 'F:/Xilinx/Vivado/2020.1'
)
$ErrorActionPreference = 'Stop'
if ($MaxWidth % 16) { throw 'MaxWidth must be a multiple of 16' }
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
# Vivado's core Tcl feature also loads its bundled Python 2 runtime.
# Keep this process-local; never change the user's Python installation.
$taskPython = "$VivadoRoot/tps/win64/python-2.7.16"
$env:RDI_PYTHONHOME = $taskPython
$env:PYTHONHOME = $taskPython
$env:PYTHONPATH = "$taskPython;$taskPython/lib;$taskPython/DLLs;$taskPython/lib/site-packages"
$env:PATH = "$VivadoRoot/bin;$taskPython;$taskPython/DLLs;" + $env:PATH
$env:RT_LIBPATH = "$VivadoRoot/scripts/rt/data"
$env:RT_TCL_PATH = "$VivadoRoot/scripts/rt/base_tcl/tcl"
$env:SYNTH_COMMON = $env:RT_LIBPATH
$env:RDI_BUILD = 'yes'
$env:ISL_IOSTREAMS_RSA = "$VivadoRoot/tps/isl"
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskBuild = Join-Path $env:TEMP ('xilinx_mjpeg_synth_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl" -Destination $taskBuild -Recurse
Copy-Item -LiteralPath "$PSScriptRoot/synth_ooc.tcl" -Destination $taskBuild
Push-Location $taskBuild
try {
    $taskPeriod = $PeriodNs.ToString([Globalization.CultureInfo]::InvariantCulture)
    & "$VivadoRoot/bin/unwrapped/win64.o/vivado.exe" -mode batch -source synth_ooc.tcl -tclargs $Part $Channels $MaxWidth $taskPeriod
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath SYNTHESIS_COMPLETE.txt)) {
        throw 'OOC synthesis failed; inspect SYN_BUILD'
    }
    $taskReport = Join-Path $taskRoot ('reports/synth_' + $Part + '_' + $Channels + 'ch_' + $MaxWidth + 'px_' + (Get-Date -Format yyyyMMdd_HHmmss))
    New-Item -ItemType Directory -Path $taskReport | Out-Null
    Get-ChildItem -File *.rpt, *.log, *.jou, core_clock.xdc, synth_ooc.tcl, SYNTHESIS_COMPLETE.txt | Copy-Item -Destination $taskReport
    $taskHashes = Get-ChildItem rtl -Recurse -File | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName.Substring($taskBuild.Length + 1).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
    [pscustomobject]@{
        part = $Part; channels = $Channels; max_width = $MaxWidth
        period_ns = $PeriodNs; clock_loaded_before_synthesis = $true
        rtl = @($taskHashes)
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$taskReport/build_manifest.json" -Encoding utf8
    Write-Output "SYNTHESIS_COMPLETE: $taskReport (not a routed timing result)"
} finally {
    Pop-Location
    Write-Output "SYN_BUILD: $taskBuild"
}
