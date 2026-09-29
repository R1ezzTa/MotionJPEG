param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='E:/anaconda/123/python.exe',
      [string]$SpatialSourceOverride='', [string]$ReportName='simulation_spatial_skip')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_spatial_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
if($SpatialSourceOverride){Copy-Item -LiteralPath $SpatialSourceOverride -Destination "$taskBuild/rtl/video/jpeg_spatial_skip.v"}
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'Spatial RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_jpeg_restart.sv tb/tb_mjpeg_spatial_board.sv tb/tb_mjpeg_spatial_throughput.sv
    if($LASTEXITCODE -ne 0){throw 'Spatial TB compile failed'}
    & "$taskBin/xelab.exe" tb_jpeg_restart -s spatial_restart --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'Spatial elaboration failed'}
    & "$taskBin/xsim.exe" spatial_restart -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path JPEG_RESTART_PASS.txt)){throw 'Spatial simulation failed'}
    $taskReport="$taskRoot/reports/mjpeg_board_test/$ReportName"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -Path restart_*.jpg,spatial_*.spj,JPEG_RESTART_PASS.txt,xsim.log,xvlog.log,xelab.log -Destination $taskReport
    & $Python "$taskRoot/tb/verify_spatial_restart.py" $taskReport
    if($LASTEXITCODE -ne 0){throw 'Independent spatial verification failed'}
    foreach($taskTop in @('tb_mjpeg_spatial_board','tb_mjpeg_spatial_throughput')) {
        & "$taskBin/xelab.exe" $taskTop -s $taskTop --debug off --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'Spatial integration elaboration failed'}
        & "$taskBin/xsim.exe" $taskTop -runall -onfinish quit
        if($LASTEXITCODE -ne 0){throw 'Spatial integration simulation failed'}
    }
    if(!(Test-Path BOARD_CONTROLS_SIM_PASS.txt) -or !(Test-Path CORE_THROUGHPUT_SIM_PASS.txt)){throw 'Missing spatial integration pass markers'}
    Copy-Item -Path board_controls_capture.bin,core_fhd_*.jpg,core_timings.json,BOARD_CONTROLS_SIM_PASS.txt,CORE_THROUGHPUT_SIM_PASS.txt -Destination $taskReport
    & $Python "$taskRoot/tb/verify_spatial_board.py" "$taskReport/board_controls_capture.bin"
    if($LASTEXITCODE -ne 0){throw 'Spatial board integration verification failed'}
    & $Python "$taskRoot/tb/verify_spatial_throughput.py" $taskReport
    if($LASTEXITCODE -ne 0){throw 'Spatial throughput verification failed'}
    Write-Output "SPATIAL_SIM_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "SPATIAL_SIM_BUILD=$taskBuild"}
