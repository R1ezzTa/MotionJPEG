param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='python',
      [ValidateRange(0,1)][int]$AdmitAtHref=0)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_real_camera_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'Real camera RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_mjpeg_real_camera.sv
    if($LASTEXITCODE -ne 0){throw 'Real camera TB compile failed'}
    & "$taskBin/xelab.exe" tb_mjpeg_real_camera -s real_camera --generic_top "ADMIT_AT_HREF=$AdmitAtHref" --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'Real camera elaboration failed'}
    & "$taskBin/xsim.exe" real_camera -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path REAL_CAMERA_SIM_PASS.txt)){throw 'Real camera simulation failed'}
    $taskReport=if($AdmitAtHref -eq 1){"$taskRoot/reports/mjpeg_board_test/simulation_real_camera_href"}else{"$taskRoot/reports/mjpeg_board_test/simulation_real_camera"}
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath real_camera_capture.bin,REAL_CAMERA_SIM_PASS.txt,xsim.log,xvlog.log,xelab.log -Destination $taskReport
    & $Python "$taskRoot/tb/verify_real_camera_capture.py" "$taskReport/real_camera_capture.bin" "$taskRoot/data/progressive_test/48x16.expected.jpg"
    if($LASTEXITCODE -ne 0){throw 'Independent real camera capture verification failed'}
    [ordered]@{ADMIT_AT_HREF=$AdmitAtHref;golden_fixture='data/progressive_test/48x16.expected.jpg';completed=(Get-Date -Format o)} |
        ConvertTo-Json | Set-Content -LiteralPath "$taskReport/simulation_configuration.json" -Encoding UTF8
    Write-Output "REAL_CAMERA_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "REAL_CAMERA_SIM_BUILD=$taskBuild"}
