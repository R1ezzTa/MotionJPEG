param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='E:/anaconda/123/python.exe',[switch]$SkipThroughput)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_threshold_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    & $Python "$taskRoot/tb/make_threshold_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'Threshold vector generation failed'}
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'Threshold RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_jpeg_threshold.sv tb/tb_camera_board_controls.sv tb/tb_mjpeg_threshold_throughput.sv
    if($LASTEXITCODE -ne 0){throw 'Threshold TB compile failed'}
    foreach($taskTop in @('tb_jpeg_threshold','tb_camera_board_controls')) {
        & "$taskBin/xelab.exe" $taskTop -s $taskTop --debug off --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'Threshold elaboration failed'}
        & "$taskBin/xsim.exe" $taskTop -runall -onfinish quit
        if($LASTEXITCODE -ne 0){throw 'Threshold simulation failed'}
    }
    if(!(Test-Path JPEG_THRESHOLD_PASS.txt)){throw 'Missing threshold pass marker'}
    & $Python "$taskRoot/tb/verify_threshold_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'Threshold independent verification failed'}
    if(!$SkipThroughput) {
    & "$taskBin/xelab.exe" tb_mjpeg_threshold_throughput -s tb_mjpeg_threshold_throughput --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'Threshold 1080p elaboration failed'}
    & "$taskBin/xsim.exe" tb_mjpeg_threshold_throughput -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path CORE_THROUGHPUT_SIM_PASS.txt)){throw 'Threshold 1080p simulation failed'}
    }
    $taskReport="$taskRoot/reports/mjpeg_board_test/simulation_threshold"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -Path threshold_*.spj,expected_threshold_*.spj,threshold_expected.json,JPEG_THRESHOLD_PASS.txt,xsim.log -Destination $taskReport
    if(!$SkipThroughput) {
    Copy-Item -Path core_fhd_*.jpg,core_timings.json,CORE_THROUGHPUT_SIM_PASS.txt -Destination $taskReport
    & $Python "$taskRoot/tb/verify_spatial_throughput.py" $taskReport
    if($LASTEXITCODE -ne 0){throw 'Threshold 1080p reference verification failed'}
    }
    Write-Output "THRESHOLD_SIM_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "THRESHOLD_SIM_BUILD=$taskBuild"}
