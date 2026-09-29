param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_camera_capture_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    & "$taskBin/xvlog.exe" "$taskRoot/rtl/camera/camera_pixel_fifo.v" "$taskRoot/rtl/camera/ov5640_dvp_capture.v"
    if($LASTEXITCODE -ne 0){throw 'Camera RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv "$taskRoot/tb/tb_ov5640_dvp_capture.sv" "$taskRoot/tb/tb_camera_pixel_fifo.sv"
    if($LASTEXITCODE -ne 0){throw 'Camera TB compile failed'}
    $taskReport="$taskRoot/reports/mjpeg_board_test/simulation_camera_capture"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    & "$taskBin/xelab.exe" tb_camera_pixel_fifo -s camera_fifo --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'Camera FIFO elaboration failed'}
    & "$taskBin/xsim.exe" camera_fifo -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path CAMERA_PIXEL_FIFO_PASS.txt)){throw 'Camera FIFO reset/flush simulation failed'}
    Copy-Item -LiteralPath CAMERA_PIXEL_FIFO_PASS.txt -Destination $taskReport
    Get-Content CAMERA_PIXEL_FIFO_PASS.txt
    foreach($taskConfig in @(@(0,0,0),@(1,0,0),@(0,0,1),@(1,0,1),@(0,1,0),@(0,1,1))) {
        $taskOrder,$taskRaw,$taskFalling=$taskConfig
        $taskSnapshot="camera_capture_${taskOrder}_${taskRaw}_${taskFalling}"
        & "$taskBin/xelab.exe" tb_ov5640_dvp_capture -s $taskSnapshot --generic_top "YUV_BYTE_ORDER=$taskOrder" --generic_top "RAW8=$taskRaw" --generic_top "SAMPLE_FALLING=$taskFalling" --debug off --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'Camera elaboration failed'}
        & "$taskBin/xsim.exe" $taskSnapshot -runall -onfinish quit
        if($LASTEXITCODE -ne 0 -or !(Test-Path CAMERA_CAPTURE_PASS.txt)){throw 'Camera capture simulation failed'}
        Copy-Item -LiteralPath CAMERA_CAPTURE_PASS.txt -Destination "$taskReport/CAMERA_CAPTURE_ORDER${taskOrder}_RAW${taskRaw}_FALL${taskFalling}_PASS.txt"
        Get-Content CAMERA_CAPTURE_PASS.txt
        Remove-Item -LiteralPath CAMERA_CAPTURE_PASS.txt
    }
    Copy-Item -LiteralPath xsim.log,xvlog.log,xelab.log -Destination $taskReport
} finally {Pop-Location;Write-Output "CAMERA_SIM_BUILD=$taskBuild"}
