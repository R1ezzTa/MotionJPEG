param([string]$VivadoRoot = 'F:/Xilinx/Vivado/2020.1', [switch]$BoardTest)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
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
$taskProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $taskProjectRoot
try {
    $taskImportScript = if ($BoardTest) {'scripts/activate_mjpeg_board_test.tcl'} else {'scripts/import_sources.tcl'}
    & "$VivadoRoot/bin/unwrapped/win64.o/vivado.exe" -mode batch -source $taskImportScript -log reports/import.log -journal reports/import.jou -tclargs --batch
    if ($LASTEXITCODE -ne 0) { throw "Source import failed: $LASTEXITCODE" }
}
finally {
    Pop-Location
}
