param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',[string]$Python='python',
    [ValidateRange(0,1)][int]$SpatialDdr=0,[ValidateRange(0,1)][int]$PreprocessEnable=0)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('mjpeg_board_controls_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl","$taskRoot/tb","$taskRoot/data" -Destination $taskBuild -Recurse
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    $taskSources=@(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object {$_.FullName})
    & "$taskBin/xvlog.exe" -i . @taskSources
    if($LASTEXITCODE -ne 0){throw 'Board controls RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb/tb_camera_board_controls.sv tb/tb_mjpeg_board_controls.sv
    if($LASTEXITCODE -ne 0){throw 'Board controls TB compile failed'}
    foreach($taskTop in @('tb_camera_board_controls','tb_mjpeg_board_controls')) {
        $taskGeneric=if($taskTop -eq 'tb_mjpeg_board_controls'){@('--generic_top',"SPATIAL_DDR=$SpatialDdr",'--generic_top',"PREPROCESS_ENABLE=$PreprocessEnable")}else{@()}
        & "$taskBin/xelab.exe" $taskTop -s $taskTop --debug off --timescale 1ns/1ps @taskGeneric
        if($LASTEXITCODE -ne 0){throw 'Board controls elaboration failed'}
        & "$taskBin/xsim.exe" $taskTop -runall -onfinish quit
        if($LASTEXITCODE -ne 0){throw 'Board controls simulation failed'}
    }
    if(!(Test-Path BUTTON_DEBOUNCE_PASS.txt) -or !(Test-Path BOARD_CONTROLS_SIM_PASS.txt)){throw 'Missing pass markers'}
    $taskReport=if($SpatialDdr){"$taskRoot/reports/mjpeg_board_test/simulation_board_controls_independent_ddr"}else{"$taskRoot/reports/mjpeg_board_test/simulation_board_controls"}
    if($PreprocessEnable){$taskReport+='_preprocess'}
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Copy-Item -LiteralPath board_controls_capture.bin,BUTTON_DEBOUNCE_PASS.txt,BOARD_CONTROLS_SIM_PASS.txt,xsim.log,xvlog.log,xelab.log -Destination $taskReport
    & $Python "$taskRoot/tb/verify_board_controls_capture.py" "$taskReport/board_controls_capture.bin"
    if($LASTEXITCODE -ne 0){throw 'Independent board controls verification failed'}
    Write-Output "BOARD_CONTROLS_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "BOARD_CONTROLS_SIM_BUILD=$taskBuild"}
