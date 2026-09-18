param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_progressive_sim_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_mjpeg_progressive.sv
    if($LASTEXITCODE -ne 0){throw 'Progressive TB compile failed'}
    & "$taskBin/xelab.exe" tb_mjpeg_progressive -s progressive --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'Progressive elaboration failed'}
    & "$taskBin/xsim.exe" progressive -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path PROGRESSIVE_SIM_PASS.txt)){throw 'Progressive simulation failed'}
    $taskReport="$taskRoot/reports/mjpeg_board_test/simulation_progressive"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath progressive_capture.bin,timing_expected.json,PROGRESSIVE_SIM_PASS.txt,xsim.log,xvlog.log,xelab.log -Destination $taskReport
    Write-Output "PROGRESSIVE_SIM_CAPTURE=$taskReport/progressive_capture.bin"
} finally {Pop-Location;Write-Output "PROGRESSIVE_SIM_BUILD=$taskBuild"}
