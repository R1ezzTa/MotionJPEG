param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_core_throughput_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'Core RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_mjpeg_core_throughput.sv
    if($LASTEXITCODE -ne 0){throw 'Core TB compile failed'}
    & "$taskBin/xelab.exe" tb_mjpeg_core_throughput -s core_throughput --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'Core elaboration failed'}
    & "$taskBin/xsim.exe" core_throughput -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path CORE_THROUGHPUT_SIM_PASS.txt)){throw 'Core throughput simulation failed'}
    $taskReport="$taskRoot/reports/mjpeg_board_test/simulation_core_throughput"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath core_fhd_0.jpg,core_fhd_1.jpg,core_timings.json,CORE_THROUGHPUT_SIM_PASS.txt,xsim.log -Destination $taskReport
    Write-Output "CORE_THROUGHPUT_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "CORE_THROUGHPUT_BUILD=$taskBuild"}
