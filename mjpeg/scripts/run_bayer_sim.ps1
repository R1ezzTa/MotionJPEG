param([int]$Width=16,[int]$Height=8,[int]$Frames=3,[switch]$Constant,
    [ValidateSet('BGGR','GRBG','GBRG','RGGB')][string]$Pattern='BGGR',
    [ValidateRange(0,1)][int]$DenoiseEnable=0,[ValidateRange(0,255)][int]$DenoiseStrength=0,
    [string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path "$PSScriptRoot/../..").Path
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskPatternId=@('BGGR','GRBG','GBRG','RGGB').IndexOf($Pattern)
$taskSim=Join-Path $taskRoot "work/bayer_sim_${Width}x${Height}_${Pattern}_nr${DenoiseEnable}_${DenoiseStrength}_v2"
New-Item -ItemType Directory -Force -Path $taskSim | Out-Null
Push-Location $taskSim
try {
    $taskReferenceArgs=@('--width',$Width,'--height',$Height,'--frames',$Frames,'--pattern',$Pattern,'--output',$taskSim,'--denoise-strength',$DenoiseStrength)
    if($Constant){$taskReferenceArgs+='--constant'}
    & 'E:/anaconda/123/python.exe' "$taskRoot/mjpeg/tb/make_bayer_reference.py" @taskReferenceArgs
    if($LASTEXITCODE){throw 'Reference generation failed'}
    $taskNrSources=@('spatial_window_3x3.v','spatial_median_yuv_3x3.v','spatial_chroma_yuv_3x3.v','spatial_denoise_yuv.v') | ForEach-Object {"$taskRoot/mjpeg/rtl/camera/$_"}
    & "$VivadoRoot/bin/unwrapped/win64.o/xvlog.exe" --sv @taskNrSources "$taskRoot/mjpeg/rtl/camera/bayer_bggr_to_yuv422.v" "$taskRoot/mjpeg/tb/tb_bayer_bggr.sv"
    if($LASTEXITCODE){throw 'xvlog failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xelab.exe" tb_bayer_bggr -generic_top "W=$Width" -generic_top "H=$Height" -generic_top "FRAMES=$Frames" -generic_top "BAYER_PATTERN=$taskPatternId" -generic_top "DENOISE_ENABLE=$DenoiseEnable" -generic_top "DENOISE_STRENGTH=$DenoiseStrength" -s bayer_sim
    if($LASTEXITCODE){throw 'xelab failed'}
    & "$VivadoRoot/bin/unwrapped/win64.o/xsim.exe" bayer_sim -runall
    if($LASTEXITCODE -or (Get-Content xsim.log -Raw) -notmatch 'PASS reflected Bayer'){throw 'Bayer test failed'}
    $taskReport=Join-Path $taskRoot "mjpeg/reports/mjpeg_board_test/simulation_bayer_${Width}x${Height}_${Pattern}_nr${DenoiseEnable}_${DenoiseStrength}_v2"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath xsim.log,xvlog.log,xelab.log -Destination $taskReport
} finally {Pop-Location}
