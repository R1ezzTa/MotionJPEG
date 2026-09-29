param([string]$VivadoRoot='F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Join-Path $env:TEMP ('ddr3_burst_bridge_'+[guid]::NewGuid().ToString('N'))
$taskReport=Join-Path $taskRoot 'reports/mjpeg_board_test/simulation_ddr3_burst_bridge'
New-Item -ItemType Directory -Path $taskBuild | Out-Null
New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl/memory/ddr3_burst_bridge.v","$taskRoot/tb/tb_ddr3_burst_bridge.sv" -Destination $taskBuild
Push-Location $taskBuild
try {
    $taskBin="$VivadoRoot/bin/unwrapped/win64.o"
    & "$taskBin/xvlog.exe" ddr3_burst_bridge.v
    if($LASTEXITCODE -ne 0){throw 'DDR3 bridge RTL compile failed'}
    & "$taskBin/xvlog.exe" --sv tb_ddr3_burst_bridge.sv
    if($LASTEXITCODE -ne 0){throw 'DDR3 bridge TB compile failed'}
    & "$taskBin/xelab.exe" tb_ddr3_burst_bridge -s ddr3_bridge --debug off --timescale 1ns/1ps
    if($LASTEXITCODE -ne 0){throw 'DDR3 bridge elaboration failed'}
    $taskCases=@(@{Seed=1;Half='3.5'},@{Seed=79;Half='6.5'},@{Seed=101;Half='11.0'},@{Seed=357;Half='4.3'})
    foreach($taskCase in $taskCases){
        $taskMarker=Join-Path $taskBuild 'DDR3_BURST_BRIDGE_PASS.txt'
        if(Test-Path -LiteralPath $taskMarker){Remove-Item -LiteralPath $taskMarker}
        & "$taskBin/xsim.exe" ddr3_bridge -testplusarg "SEED=$($taskCase.Seed)" -testplusarg "UI_HALF=$($taskCase.Half)" -runall -onfinish quit
        if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $taskMarker)){throw "DDR3 bridge simulation failed, seed $($taskCase.Seed)"}
        Copy-Item -LiteralPath $taskMarker -Destination (Join-Path $taskReport "seed_$($taskCase.Seed)_PASS.txt")
        Copy-Item -LiteralPath xsim.log -Destination (Join-Path $taskReport "seed_$($taskCase.Seed)_xsim.log")
        Get-Content -LiteralPath $taskMarker
    }
    Copy-Item -LiteralPath xvlog.log,xelab.log -Destination $taskReport
    Write-Output "DDR3_BURST_BRIDGE_REPORT=$taskReport"
} finally {Pop-Location;Write-Output "DDR3_BURST_BRIDGE_SIM_BUILD=$taskBuild"}
