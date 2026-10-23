param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_sync_sim_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_board_test_async_fifo.sv
    if($LASTEXITCODE -ne 0){throw 'Sync TB compile failed'}
    & "$taskBin/xelab.exe" tb_board_test_async_fifo -s cdc --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'CDC elaboration failed'}
    & "$taskBin/xsim.exe" cdc -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path ASYNC_FIFO_PASS.txt)){throw 'CDC simulation failed'}
    $taskReport="$taskRoot/reports/mjpeg_board_test/simulation_async_fifo"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath ASYNC_FIFO_PASS.txt,xsim.log,xvlog.log,xelab.log -Destination $taskReport
    Write-Output "SYNC_SIM_PASS=$taskReport"
} finally {Pop-Location;Write-Output "SYNC_SIM_BUILD=$taskBuild"}
