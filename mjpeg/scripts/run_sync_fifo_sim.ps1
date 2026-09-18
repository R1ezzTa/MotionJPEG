param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_sync_sim_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'RTL compile failed'}
    & "$taskBin/xvlog.exe" "$VivadoRoot/data/verilog/src/glbl.v"
    if($LASTEXITCODE -ne 0){throw 'Global primitive model compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_board_test_async_fifo.sv tb/tb_davinci_mjpeg_sync_test.sv
    if($LASTEXITCODE -ne 0){throw 'Sync TB compile failed'}
    & "$taskBin/xelab.exe" tb_board_test_async_fifo -s cdc --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'CDC elaboration failed'}
    & "$taskBin/xsim.exe" cdc -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path ASYNC_FIFO_PASS.txt)){throw 'CDC simulation failed'}
    foreach($taskProgressive in @(0,1)) {
        $taskSnapshot="sync_$taskProgressive"
        & "$taskBin/xelab.exe" tb_davinci_mjpeg_sync_test glbl -L unisims_ver -s $taskSnapshot --generic_top "PROGRESSIVE=$taskProgressive" --debug off --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'Sync board elaboration failed'}
        & "$taskBin/xsim.exe" $taskSnapshot -runall -onfinish quit
        if($LASTEXITCODE -ne 0 -or !(Test-Path SYNC_BOARD_PASS.txt)){throw 'Sync board simulation failed'}
        $taskKind=if($taskProgressive){'simulation_core100_progressive'}else{'simulation_core100_small'}
        $taskCapture=if($taskProgressive){'sync_progressive_capture.bin'}else{'sync_small_capture.bin'}
        $taskReport="$taskRoot/reports/mjpeg_board_test/$taskKind"
        New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
        Copy-Item -LiteralPath $taskCapture,ASYNC_FIFO_PASS.txt,SYNC_BOARD_PASS.txt,fps_expected.csv,link_expected.csv,timing_expected.json,xsim.log,xvlog.log,xelab.log -Destination $taskReport
        Remove-Item -LiteralPath SYNC_BOARD_PASS.txt
        Write-Output "SYNC_SIM_CAPTURE=$taskReport/$taskCapture"
    }
} finally {Pop-Location;Write-Output "SYNC_SIM_BUILD=$taskBuild"}
