param([int]$Width=16,[int]$Height=8,[string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='python')
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path "$PSScriptRoot/../..").Path
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskSim=Join-Path $env:TEMP ('mjpeg_preprocess_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskSim | Out-Null
Push-Location $taskSim
try {
    & $Python "$taskRoot/mjpeg/tb/make_preprocess_vectors.py" --width $Width --height $Height --output $taskSim
    if($LASTEXITCODE){throw 'Preprocessing independent reference failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xvlog.exe" --sv "$taskRoot/mjpeg/rtl/camera/spatial_window_3x3.v" "$taskRoot/mjpeg/rtl/camera/yuv422_preprocess.v" "$taskRoot/mjpeg/tb/tb_yuv422_preprocess.sv"
    if($LASTEXITCODE){throw 'Preprocessing xvlog failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xelab.exe" tb_yuv422_preprocess -generic_top "W=$Width" -generic_top "H=$Height" -s preprocess_sim
    if($LASTEXITCODE){throw 'Preprocessing xelab failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xsim.exe" preprocess_sim -runall
    if($LASTEXITCODE -or (Get-Content xsim.log -Raw) -notmatch 'PASS YUV preprocessing'){throw 'Preprocessing simulation failed'}
    $taskReport=Join-Path $taskRoot "mjpeg/reports/mjpeg_board_test/simulation_preprocess_${Width}x${Height}"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath xsim.log,xvlog.log,xelab.log,reference_summary.json -Destination $taskReport
    Write-Output "PREPROCESS_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "PREPROCESS_SIM_BUILD=$taskSim"}
