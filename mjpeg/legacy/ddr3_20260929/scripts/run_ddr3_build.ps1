param([ValidateSet('SelfTest','Synth','Full')][string]$Action='Synth',
    [string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[ValidateRange(0,5)][int]$CameraProfile=5,
    [ValidateRange(0,1)][int]$ThresholdEnable=0,[string]$RoutedBuild='',
    [ValidateRange(0,1)][int]$SkipEnable=0,[ValidateRange(0,1)][int]$AdaptiveEnable=0,
    [ValidateRange(0,1)][int]$DenoiseEnable=1,[ValidateRange(0,1)][int]$PreprocessEnable=1)
$ErrorActionPreference='Stop'
if($DenoiseEnable -and $SkipEnable){throw 'Denoise trial uses independent JPEG; disable spatial skip, or disable denoise for a legacy skip build'}
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
$taskBuild=Join-Path $taskRoot ('reports/ddr3/'+$Action.ToLower()+'_'+(Get-Date -Format yyyyMMdd_HHmmss))
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
$taskRtlSources=@((Get-ChildItem "$taskRoot/rtl" -File -Recurse).FullName)
if($Action -eq 'SelfTest') {
    $taskRtlSources=@('rtl/top/davinci_ddr3_selftest_top.v','rtl/memory/ddr3_selftest_core.v','rtl/memory/mjpeg_ddr3_memory.v','rtl/memory/ddr3_burst_bridge.v','rtl/common/board_test_core_clock.v','rtl/usb/board_test_async_fifo.v','rtl/usb/board_test_usb_clock_guard.v','rtl/usb/board_test_ft245_sync.v' | ForEach-Object {Join-Path $taskRoot $_})
}
$taskSources=@($taskRtlSources+
    (Get-ChildItem "$taskRoot/data/board_test" -File).FullName+
    (Get-ChildItem "$taskRoot/ip/ddr3/davinci_ddr3_mig" -File -Recurse | Where-Object {$_.Extension -in '.xci','.prj','.xdc','.v','.dcp'}).FullName+
    (Get-ChildItem "$taskRoot/ip/ddr3" -Filter *.prj -File).FullName+
    "$taskRoot/constraints/davinci_mjpeg_board_test.xdc","$taskRoot/constraints/davinci_mjpeg_cdc.xdc",
    "$taskRoot/scripts/build_ddr3.tcl","$taskRoot/scripts/ddr3_cdc.tcl")
$taskHashes=Get-FileHash -LiteralPath $taskSources -Algorithm SHA256
$taskReuse='-'
if($RoutedBuild) {
    if($Action -ne 'Full'){throw 'Routed reuse is only supported for Full'}
    $taskReuse=(Resolve-Path -LiteralPath $RoutedBuild).Path
    $taskOldProfile=Get-Content -LiteralPath "$taskReuse/build_profile.json" -Raw | ConvertFrom-Json
    if(!$taskOldProfile.ddr3 -or $taskOldProfile.action -ne 'Full' -or $taskOldProfile.camera_profile -ne $CameraProfile -or $taskOldProfile.threshold_enable -ne $ThresholdEnable -or $taskOldProfile.skip_enable -ne $SkipEnable -or $taskOldProfile.adaptive_enable -ne $AdaptiveEnable -or $taskOldProfile.denoise_enable -ne $DenoiseEnable -or $taskOldProfile.preprocess_enable -ne $PreprocessEnable){throw 'Routed DDR3 profile changed'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $taskArchive=[System.IO.Compression.ZipFile]::OpenRead("$taskReuse/routed_before_checks.dcp")
    try {
        $taskReader=[System.IO.StreamReader]::new($taskArchive.GetEntry('dcp.xml').Open())
        try {$taskCheckpointXml=[xml]$taskReader.ReadToEnd()} finally {$taskReader.Dispose()}
        if($taskCheckpointXml.Checkpoint.Top.Name -ne 'davinci_mjpeg_ddr3_top' -or $taskCheckpointXml.Checkpoint.Part.Name -ne 'xc7a35tfgg484-2'){throw 'Routed checkpoint top/part changed'}
    } finally {$taskArchive.Dispose()}
    $taskOldHashes=@(Get-Content -LiteralPath "$taskReuse/build_input_hashes.json" -Raw | ConvertFrom-Json)
    foreach($taskOldHash in $taskOldHashes) {
        $taskCompare=$taskOldHash.Path
        if($taskCompare -eq "$taskRoot/scripts/build_ddr3.tcl" -or $taskCompare -eq "$taskRoot\scripts\build_ddr3.tcl"){
            # Only the final review policy can change. Preserve and verify the
            # original build script; all RTL, IP and physical constraints match.
            $taskCompare="$taskReuse/build_ddr3_source.tcl"
        }
        if((Get-FileHash -LiteralPath $taskCompare -Algorithm SHA256).Hash -ne $taskOldHash.Hash){throw "Routed source changed: $taskCompare"}
    }
    foreach($taskHash in $taskHashes){if(!($taskOldHashes | Where-Object {$_.Path -eq $taskHash.Path})){throw "Routed source inventory changed: $($taskHash.Path)"}}
    $taskSources+=@("$taskReuse/routed_before_checks.dcp","$taskReuse/build_ddr3_source.tcl","$taskReuse/build_input_hashes.json","$taskReuse/board_profile.xdc")
    $taskHashes=Get-FileHash -LiteralPath $taskSources -Algorithm SHA256
}
$taskHashes | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_input_hashes.json" -Encoding utf8
Copy-Item -LiteralPath "$taskRoot/scripts/build_ddr3.tcl" -Destination "$taskBuild/build_ddr3_source.tcl"
@{action=$Action;camera_profile=$CameraProfile;threshold_enable=$ThresholdEnable;skip_enable=$SkipEnable;adaptive_enable=$AdaptiveEnable;denoise_enable=$DenoiseEnable;preprocess_enable=$PreprocessEnable;ddr3=$true} | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_profile.json" -Encoding utf8
Push-Location $taskRoot
try {
    & "$VivadoRoot/bin/unwrapped/win64.o/vivado.exe" -mode batch -source scripts/build_ddr3.tcl -log "$taskBuild/build.log" -journal "$taskBuild/build.jou" -tclargs $taskRoot $taskBuild $Action $CameraProfile $ThresholdEnable $taskReuse $SkipEnable $AdaptiveEnable $DenoiseEnable $PreprocessEnable
    if($LASTEXITCODE -ne 0){throw 'DDR3 synthesis/implementation failed'}
    foreach($taskHash in $taskHashes){if((Get-FileHash -LiteralPath $taskHash.Path -Algorithm SHA256).Hash -ne $taskHash.Hash){throw "DDR3 source changed during build: $($taskHash.Path)"}}
    if($Action -ne 'Synth') {
        if(!(Test-Path -LiteralPath "$taskBuild/BUILD_PASS.txt")){throw 'DDR3 build marker missing'}
        Get-FileHash -LiteralPath @($taskSources+"$taskBuild/davinci_mjpeg_board_test.bit"+"$taskBuild/build_profile.json"+"$taskBuild/board_profile.xdc") -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_hashes.json" -Encoding utf8
    }
    Write-Output "DDR3_BUILD=$taskBuild"
} finally {Pop-Location;Write-Output "DDR3_BUILD_DIRECTORY=$taskBuild"}
