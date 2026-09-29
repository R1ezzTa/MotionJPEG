param([int]$Width=16,[int]$Height=8,[string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='python')
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path "$PSScriptRoot/../..").Path
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskSim=Join-Path $env:TEMP ('mjpeg_denoise_yuv_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskSim | Out-Null
Push-Location $taskSim
try {
    & $Python "$taskRoot/mjpeg/tb/make_denoise_yuv_vectors.py" --width $Width --height $Height --output $taskSim
    if($LASTEXITCODE){throw 'Robust YUV independent reference failed'}
    $taskSources=@('spatial_window_3x3.v','spatial_median_yuv_3x3.v','spatial_chroma_yuv_3x3.v','spatial_denoise_yuv.v') | ForEach-Object {"$taskRoot/mjpeg/rtl/camera/$_"}
    & "$VivadoRoot/bin/unwrapped/win64.o/xvlog.exe" --sv @taskSources "$taskRoot/mjpeg/tb/tb_spatial_denoise_yuv.sv"
    if($LASTEXITCODE){throw 'Robust YUV xvlog failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xelab.exe" tb_spatial_denoise_yuv -generic_top "W=$Width" -generic_top "H=$Height" -s denoise_yuv_sim
    if($LASTEXITCODE){throw 'Robust YUV xelab failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xsim.exe" denoise_yuv_sim -runall
    if($LASTEXITCODE -or (Get-Content xsim.log -Raw) -notmatch 'PASS robust YUV denoise independent reference'){throw 'Robust YUV simulation failed'}
    $taskReport=Join-Path $taskRoot "mjpeg/reports/mjpeg_board_test/simulation_denoise_yuv_${Width}x${Height}"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath xsim.log,xvlog.log,xelab.log,reference_summary.json -Destination $taskReport
    Write-Output "DENOISE_YUV_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "DENOISE_YUV_SIM_BUILD=$taskSim"}
