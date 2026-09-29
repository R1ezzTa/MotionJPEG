param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='E:/anaconda/123/python.exe')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_adaptive_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    & $Python "$taskRoot/tb/make_adaptive_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'Adaptive reference generation failed'}
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    & "$taskBin/xvlog.exe" -i . rtl/video/jpeg_coefficient_decoder.v rtl/video/jpeg_spatial_skip_ddr.v rtl/board/camera_board_controls.v
    if($LASTEXITCODE -ne 0){throw 'Adaptive RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/spatial_ddr_memory_model.sv tb/tb_jpeg_threshold_ddr.sv tb/tb_jpeg_adaptive_ddr.sv tb/tb_camera_board_controls.sv
    if($LASTEXITCODE -ne 0){throw 'Adaptive TB compile failed'}
    foreach($taskTop in @('tb_camera_board_controls','tb_jpeg_adaptive_ddr','tb_jpeg_adaptive_ddr_full','tb_jpeg_adaptive_ddr_budget','tb_jpeg_adaptive_ddr_queue','tb_jpeg_adaptive_ddr_pressure')) {
        & "$taskBin/xelab.exe" $taskTop -s $taskTop --debug off --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw "Adaptive elaboration failed: $taskTop"}
        & "$taskBin/xsim.exe" $taskTop -runall -onfinish quit
        $taskPass=@{tb_camera_board_controls='BUTTON_DEBOUNCE_PASS.txt';tb_jpeg_adaptive_ddr='ADAPTIVE_DDR_PASS.txt';tb_jpeg_adaptive_ddr_full='ADAPTIVE_DDR_FULL_PASS.txt';tb_jpeg_adaptive_ddr_budget='ADAPTIVE_DDR_BUDGET_PASS.txt';tb_jpeg_adaptive_ddr_queue='ADAPTIVE_DDR_QUEUE_PASS.txt';tb_jpeg_adaptive_ddr_pressure='ADAPTIVE_DDR_PRESSURE_PASS.txt'}[$taskTop]
        if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $taskPass)){throw "Adaptive simulation failed: $taskTop"}
    }
    & $Python -c "from pathlib import Path; p=Path('.'); pairs=[(e,p/e.name.replace('expected_','',1)) for e in p.glob('expected_adaptive*.spj')]; assert len(pairs)==88; assert all(a.read_bytes()==b.read_bytes() for a,b in pairs), 'Adaptive output differs from independent reference'; print('ADAPTIVE_REFERENCE_PASS: all 88 packets byte-identical')"
    if($LASTEXITCODE -ne 0){throw 'Adaptive independent verification failed'}
    $taskReport="$taskRoot/reports/mjpeg_board_test/simulation_adaptive_ddr"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -Path adaptive*.spj,expected_adaptive*.spj,adaptive*_expected.json,ADAPTIVE_DDR*.txt,BUTTON_DEBOUNCE_PASS.txt,xsim.log -Destination $taskReport
    Write-Output "ADAPTIVE_SIM_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "ADAPTIVE_SIM_BUILD=$taskBuild"}
