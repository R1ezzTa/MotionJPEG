param(
    [ValidateSet('Synth','Full')][string]$Action='Full',
    [string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',
    [ValidateRange(0,1)][int]$DenoiseEnable=1,
    [ValidateRange(0,1)][int]$PreprocessEnable=1
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskPython="$VivadoRoot/tps/win64/python-2.7.16"
$env:RDI_PYTHONHOME=$taskPython
$env:PYTHONHOME=$taskPython
$env:PYTHONPATH="$taskPython;$taskPython/lib;$taskPython/DLLs;$taskPython/lib/site-packages"
$env:PATH="$VivadoRoot/bin;$taskPython;$taskPython/DLLs;"+$env:PATH
$env:RT_LIBPATH="$VivadoRoot/scripts/rt/data"
$env:RT_TCL_PATH="$VivadoRoot/scripts/rt/base_tcl/tcl"
$env:SYNTH_COMMON=$env:RT_LIBPATH
$env:RDI_BUILD='yes'
$env:ISL_IOSTREAMS_RSA="$VivadoRoot/tps/isl"
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $taskRoot ('reports/camera/'+$Action.ToLower()+'_'+(Get-Date -Format yyyyMMdd_HHmmss))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
$taskSources=@(Get-Content "$PSScriptRoot/camera_sources.txt" | Where-Object {$_ -and !($_.StartsWith('#'))} | ForEach-Object {Join-Path $taskRoot $_})
$taskSources+=@((Get-ChildItem "$taskRoot/data/board_test" -File).FullName+
    "$taskRoot/constraints/davinci_mjpeg_camera.xdc","$taskRoot/constraints/davinci_mjpeg_cdc.xdc",
    "$PSScriptRoot/camera_sources.txt","$PSScriptRoot/build_camera.tcl","$PSScriptRoot/run_camera_build.ps1","$PSScriptRoot/vivado_env.ps1")
$taskHashes=Get-FileHash -LiteralPath $taskSources -Algorithm SHA256
$taskHashes | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_input_hashes.json" -Encoding utf8
Copy-Item -LiteralPath "$PSScriptRoot/build_camera.tcl" -Destination "$taskBuild/build_camera_source.tcl"
@{action=$Action;top='davinci_mjpeg_camera_top';camera_profile=5;ddr3=$false;skip_enable=0;threshold_enable=0;adaptive_enable=0;denoise_enable=$DenoiseEnable;preprocess_enable=$PreprocessEnable;lut_limit_percent=80} | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_profile.json" -Encoding utf8
Push-Location $taskRoot
try {
    & "$VivadoRoot/bin/unwrapped/win64.o/vivado.exe" -mode batch -source scripts/build_camera.tcl -log "$taskBuild/build.log" -journal "$taskBuild/build.jou" -tclargs $taskRoot $taskBuild $Action $DenoiseEnable $PreprocessEnable
    if($LASTEXITCODE -ne 0){throw 'Independent camera synthesis/implementation failed'}
    foreach($taskHash in $taskHashes){if((Get-FileHash -LiteralPath $taskHash.Path -Algorithm SHA256).Hash -ne $taskHash.Hash){throw "Source changed during build: $($taskHash.Path)"}}
    if($Action -eq 'Full') {
        if(!(Test-Path -LiteralPath "$taskBuild/BUILD_PASS.txt")){throw 'Camera build marker missing'}
        Get-FileHash -LiteralPath @($taskSources+"$taskBuild/davinci_mjpeg_board_test.bit"+"$taskBuild/build_profile.json"+"$taskBuild/board_profile.xdc") -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_hashes.json" -Encoding utf8
        Set-Content -LiteralPath "$taskRoot/reports/camera/latest_build.txt" -Value $taskBuild -Encoding utf8
    }
    Write-Output "CAMERA_BUILD=$taskBuild"
} finally {Pop-Location;Write-Output "CAMERA_BUILD_DIRECTORY=$taskBuild"}
