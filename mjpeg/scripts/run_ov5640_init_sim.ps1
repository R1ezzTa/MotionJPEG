param([string]$VivadoRoot = 'F:/Xilinx/Vivado/2020.1', [int]$CameraProfile=0)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$sim = Join-Path $repo 'work/ov5640_init_sim'
New-Item -ItemType Directory -Force $sim | Out-Null
Push-Location $sim
try {
    & "$VivadoRoot/bin/unwrapped/win64.o/xvlog.exe" --sv "$repo/mjpeg/rtl/camera/ov5640_sccb_master.v" "$repo/mjpeg/rtl/camera/ov5640_init.v" "$repo/mjpeg/tb/tb_ov5640_init.sv"
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & "$VivadoRoot/bin/unwrapped/win64.o/xelab.exe" tb_ov5640_init -generic_top "CAMERA_PROFILE=$CameraProfile" -s ov5640_init_sim
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & "$VivadoRoot/bin/unwrapped/win64.o/xsim.exe" ov5640_init_sim -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    $log = Get-Content -LiteralPath 'xsim.log' -Raw
    if ($log -match 'Fatal:' -or $log -notmatch 'PASS persistent NACK diagnosis') { throw 'OV5640 simulation assertions failed' }
} finally { Pop-Location }
