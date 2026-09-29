param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=(Resolve-Path "$PSScriptRoot/../..").Path
$taskSim=Join-Path $taskRoot 'work/camera_clock_sim'
New-Item -ItemType Directory -Force -Path $taskSim | Out-Null
Push-Location $taskSim
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    & "$taskBin/xvlog.exe" --sv "$taskRoot/mjpeg/rtl/camera/ov5640_sample_clock.v" "$taskRoot/mjpeg/tb/tb_ov5640_sample_clock.sv" "$VivadoRoot/data/verilog/src/glbl.v"
    if($LASTEXITCODE){throw 'Camera clock compile failed'}
    & "$taskBin/xelab.exe" tb_ov5640_sample_clock glbl -L unisims_ver -s camera_clock_sim
    if($LASTEXITCODE){throw 'Camera clock elaboration failed'}
    & "$taskBin/xsim.exe" camera_clock_sim -runall
    if($LASTEXITCODE -or (Get-Content xsim.log -Raw) -notmatch 'PASS real MMCM primitive'){throw 'Camera clock test failed'}
    $taskReport=Join-Path $taskRoot 'mjpeg/reports/mjpeg_board_test/simulation_camera_clock'
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath xsim.log,xvlog.log,xelab.log -Destination $taskReport
} finally {Pop-Location}
