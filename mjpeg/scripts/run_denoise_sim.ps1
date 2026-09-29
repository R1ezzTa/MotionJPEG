param([int]$Width=16,[int]$Height=8,[string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path "$PSScriptRoot/../..").Path
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskSim=Join-Path $env:TEMP ('mjpeg_denoise_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskSim | Out-Null
Push-Location $taskSim
try {
    & 'E:/anaconda/123/python.exe' "$taskRoot/mjpeg/tb/make_denoise_vectors.py" --width $Width --height $Height --output $taskSim
    if($LASTEXITCODE){throw 'Denoise independent reference failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xvlog.exe" --sv "$taskRoot/mjpeg/rtl/camera/spatial_denoise_rgb_3x3.v" "$taskRoot/mjpeg/tb/tb_spatial_denoise_rgb.sv"
    if($LASTEXITCODE){throw 'Denoise xvlog failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xelab.exe" tb_spatial_denoise_rgb -generic_top "W=$Width" -generic_top "H=$Height" -s denoise_sim
    if($LASTEXITCODE){throw 'Denoise xelab failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xsim.exe" denoise_sim -runall
    if($LASTEXITCODE -or (Get-Content xsim.log -Raw) -notmatch 'PASS spatial RGB denoise independent reference'){throw 'Denoise simulation failed'}
    $taskReport=Join-Path $taskRoot "mjpeg/reports/mjpeg_board_test/simulation_denoise_${Width}x${Height}"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath xsim.log,xvlog.log,xelab.log,reference_summary.json -Destination $taskReport
    Write-Output "DENOISE_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "DENOISE_SIM_BUILD=$taskSim"}
