param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='E:/anaconda/123/python.exe')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$recoveryBuild=Join-Path $env:TEMP ('mjpeg_ddr_quant_recovery_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $recoveryBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $recoveryBuild -Recurse
Push-Location $recoveryBuild
try {
    $recoveryBin="$VivadoRoot/bin/unwrapped/win64.o"
    $recoverySources=@(Get-ChildItem rtl/core -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    $recoverySources+=@('rtl/common/line_group_ram.v','rtl/common/jpeg_stream_buffer.v','rtl/video/jpeg_coefficient_decoder.v','rtl/video/jpeg_spatial_skip_ddr.v','rtl/video/mjpeg_channel.v')
    $recoveryHashes=Get-FileHash -Algorithm SHA256 -LiteralPath $recoverySources
    $recoveryHashes | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath recovery_source_hashes.json -Encoding utf8
    & "$recoveryBin/xvlog.exe" -i . @recoverySources
    if($LASTEXITCODE -ne 0){throw 'Recovery RTL compile failed'}
    & "$recoveryBin/xvlog.exe" --sv tb/spatial_ddr_memory_model.sv tb/tb_ddr_channel_quant_recovery.sv
    if($LASTEXITCODE -ne 0){throw 'Recovery TB compile failed'}
    & "$recoveryBin/xelab.exe" tb_ddr_channel_quant_recovery -s recovery --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'Recovery elaboration failed'}
    & "$recoveryBin/xsim.exe" recovery -runall -onfinish quit
    if($LASTEXITCODE -ne 0 -or !(Test-Path DDR_CHANNEL_QUANT_RECOVERY_PASS.txt)){throw 'Recovery simulation failed'}
    & $Python "$taskRoot/tb/verify_ddr_channel_recovery.py" $recoveryBuild
    if($LASTEXITCODE -ne 0){throw 'Recovery output verification failed'}
    $recoveryReport="$taskRoot/reports/mjpeg_board_test/simulation_ddr_channel_recovery"
    New-Item -ItemType Directory -Force -Path $recoveryReport | Out-Null
    Copy-Item -Path quant_recovery_frame*.spj,DDR_CHANNEL_QUANT_RECOVERY_PASS.txt,recovery_reference.json,recovery_source_hashes.json,xsim.log -Destination $recoveryReport
    Write-Output "QUANT_RECOVERY_REPORT=$recoveryReport"
} finally {Pop-Location;Write-Output "QUANT_RECOVERY_BUILD=$recoveryBuild"}
