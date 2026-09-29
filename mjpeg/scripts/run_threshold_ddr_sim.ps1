param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='E:/anaconda/123/python.exe',[switch]$SkipThroughput)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_threshold_ddr_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    & $Python "$taskRoot/tb/make_threshold_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'DDR threshold vector generation failed'}
    & $Python "$taskRoot/tb/make_threshold_ddr_dense_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'DDR dense vector generation failed'}
    & $Python "$taskRoot/tb/make_threshold_ddr_full_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'DDR full-position vector generation failed'}
    & $Python "$taskRoot/tb/make_threshold_ddr_early_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'DDR early rejection vector generation failed'}
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    # This isolated cache test does not depend on the board/channel/MIG files,
    # which may be edited concurrently during DDR integration.
    $taskSources=@(Get-ChildItem rtl/core -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    $taskSources+=@('rtl/common/line_group_ram.v','rtl/common/jpeg_stream_buffer.v',
        'rtl/top/board_test_gradient.v','rtl/video/jpeg_coefficient_decoder.v','rtl/video/jpeg_spatial_skip_ddr.v')
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'DDR threshold RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/spatial_ddr_memory_model.sv tb/tb_jpeg_threshold_ddr.sv tb/tb_jpeg_threshold_ddr_abort.sv tb/tb_jpeg_threshold_ddr_throughput.sv
    if($LASTEXITCODE -ne 0){throw 'DDR threshold TB compile failed'}
    foreach($taskTop in @('tb_jpeg_threshold_ddr','tb_jpeg_threshold_ddr_abort','tb_jpeg_threshold_ddr_dense','tb_jpeg_threshold_ddr_full','tb_jpeg_threshold_ddr_early')) {
        & "$taskBin/xelab.exe" $taskTop -s $taskTop --debug off --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'DDR threshold elaboration failed'}
        & "$taskBin/xsim.exe" $taskTop -runall -onfinish quit
        if($LASTEXITCODE -ne 0){throw 'DDR threshold simulation failed'}
    }
    if(!(Test-Path JPEG_THRESHOLD_DDR_PASS.txt) -or !(Test-Path JPEG_THRESHOLD_DDR_ABORT_PASS.txt)){throw 'Missing DDR threshold pass marker'}
    & $Python "$taskRoot/tb/verify_threshold_vectors.py" $taskBuild
    if($LASTEXITCODE -ne 0){throw 'DDR threshold independent verification failed'}
    & $Python "$taskRoot/tb/verify_threshold_ddr_throughput.py" $taskBuild --abort-only
    if($LASTEXITCODE -ne 0){throw 'DDR abort independent verification failed'}
    & $Python "$taskRoot/tb/verify_threshold_ddr_throughput.py" $taskBuild --dense-only
    if($LASTEXITCODE -ne 0){throw 'DDR dense independent verification failed'}
    & $Python "$taskRoot/tb/verify_threshold_ddr_throughput.py" $taskBuild --full-only
    if($LASTEXITCODE -ne 0){throw 'DDR full-position independent verification failed'}
    & $Python "$taskRoot/tb/verify_threshold_ddr_throughput.py" $taskBuild --early-only
    if($LASTEXITCODE -ne 0){throw 'DDR early rejection independent verification failed'}
    if(!$SkipThroughput) {
        & "$taskBin/xelab.exe" tb_jpeg_threshold_ddr_throughput -s tb_jpeg_threshold_ddr_throughput --debug off --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'DDR threshold FHD elaboration failed'}
        & "$taskBin/xsim.exe" tb_jpeg_threshold_ddr_throughput -runall -onfinish quit
        if($LASTEXITCODE -ne 0 -or !(Test-Path JPEG_THRESHOLD_DDR_THROUGHPUT_PASS.txt)){throw 'DDR threshold FHD simulation failed'}
        & $Python "$taskRoot/tb/verify_threshold_ddr_throughput.py" $taskBuild
        if($LASTEXITCODE -ne 0){throw 'DDR threshold FHD verification failed'}
    }
    $taskReport="$taskRoot/reports/mjpeg_board_test/simulation_threshold_ddr"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -Path threshold_*.spj,expected_threshold_*.spj,threshold_expected.json,dense_*.spj,expected_dense_*.spj,dense_expected.json,full_*.spj,expected_full_*.spj,full_expected.json,early_*.spj,expected_early_*.spj,early_expected.json,early_throughput.json,JPEG_THRESHOLD_DDR*.txt,ddr_abort_*.spj,xsim.log -Destination $taskReport
    if(!$SkipThroughput){Copy-Item -Path ddr_fhd_*,ddr_throughput.json -Destination $taskReport}
    Write-Output "THRESHOLD_DDR_SIM_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "THRESHOLD_DDR_SIM_BUILD=$taskBuild"}
