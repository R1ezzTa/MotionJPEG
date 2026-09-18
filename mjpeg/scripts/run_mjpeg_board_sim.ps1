param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1', [switch]$Uart)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_board_sim_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if ($LASTEXITCODE -ne 0) {throw 'RTL compile failed'}
    $taskTop=if($Uart){'tb_davinci_mjpeg_board_test'}else{'tb_davinci_mjpeg_fifo_test'}
    & "$taskBin/xvlog.exe" --sv "tb/$taskTop.sv"
    if ($LASTEXITCODE -ne 0) {throw 'TB compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_fps_peripherals.sv
    if ($LASTEXITCODE -ne 0) {throw 'FPS TB compile failed'}
    & "$taskBin/xelab.exe" tb_fps_peripherals -s fps_peripherals --debug off --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) {throw 'FPS elaboration failed'}
    & "$taskBin/xsim.exe" fps_peripherals -runall -onfinish quit
    if ($LASTEXITCODE -ne 0 -or !(Test-Path PERIPHERALS_PASS.txt)) {throw 'FPS peripheral simulation failed'}
    & "$taskBin/xelab.exe" $taskTop -s board_test --debug off --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) {throw 'Elaboration failed'}
    & "$taskBin/xsim.exe" board_test -runall -onfinish quit
    if ($LASTEXITCODE -ne 0 -or !(Test-Path SIM_PASS.txt)) {throw 'Simulation did not pass'}
    $taskKind=if($Uart){'simulation_uart'}else{'simulation_fifo'}
    $taskCapture=if($Uart){'uart_capture.bin'}else{'usb_capture.bin'}
    $taskReport="$taskRoot/reports/mjpeg_board_test/$taskKind"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath $taskCapture,SIM_PASS.txt,xsim.log,xvlog.log,xelab.log -Destination $taskReport
    Copy-Item -LiteralPath PERIPHERALS_PASS.txt -Destination $taskReport
    if(Test-Path fps_expected.csv){Copy-Item -LiteralPath fps_expected.csv -Destination $taskReport}
    Write-Output "SIMULATION_CAPTURE=$taskReport/$taskCapture"
} finally {Pop-Location; Write-Output "SIM_BUILD=$taskBuild"}
