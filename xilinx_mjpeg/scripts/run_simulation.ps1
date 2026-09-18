param(
    [string]$VivadoRoot = 'F:/Xilinx/Vivado/2020.1',
    [ValidateSet('tb_mjpeg_board', 'tb_mjpeg_fhd', 'tb_mjpeg_wide', 'tb_mjpeg_four', 'tb_mjpeg_mixed')]
    [string]$Top = 'tb_mjpeg_board'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskRoot = Split-Path $PSScriptRoot -Parent
# Keep XSIM's build path ASCII even when the project path contains Chinese.
$taskBuild = Join-Path $env:TEMP ('xilinx_mjpeg_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskBuild | Out-Null
Copy-Item -LiteralPath "$taskRoot/rtl", "$taskRoot/tb", "$taskRoot/data" -Destination $taskBuild -Recurse
$taskBin = "$VivadoRoot/bin/unwrapped/win64.o"
Push-Location $taskBuild
try {
    $taskSources = @(Get-ChildItem rtl -Filter *.v -Recurse | ForEach-Object { $_.FullName })
    & "$taskBin/xvlog.exe" -i . @taskSources
    if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed' }
    & "$taskBin/xvlog.exe" --sv "tb/$Top.sv" tb/tb_mjpeg_common.sv
    if ($LASTEXITCODE -ne 0) { throw 'Testbench compilation failed' }
    & "$taskBin/xelab.exe" $Top -s mjpeg_test --debug off --timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'Elaboration failed' }
    & "$taskBin/xsim.exe" mjpeg_test -runall -onfinish quit
    # XSIM can exit zero after $fatal. This new build must also have a pass marker.
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath SIM_PASS.txt)) {
        throw 'Simulation failed; inspect SIM_BUILD'
    }
    $taskKind = $Top -replace '^tb_', ''
    $taskReport = Join-Path $taskRoot "reports/$taskKind"
    New-Item -ItemType Directory -Force -Path $taskReport | Out-Null
    Get-ChildItem -File *.log, *.csv, *.jpg, SIM_PASS.txt | Copy-Item -Destination $taskReport
    $taskHashes = Get-ChildItem rtl, tb, data -Recurse -File | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName.Substring($taskBuild.Length + 1).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
    $taskHashes | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath "$taskReport/tested_sources.json" -Encoding utf8
    Write-Output "SIMULATION_PASSED: $taskReport"
} finally {
    Pop-Location
    Write-Output "SIM_BUILD: $taskBuild"
}
