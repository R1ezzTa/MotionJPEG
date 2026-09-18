param(
    [ValidateSet('Build','Help','Program','State')][string]$Action = 'Build',
    [string]$VivadoRoot = 'F:/Xilinx/Vivado/2020.1'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot
$taskPython = "$VivadoRoot/tps/win64/python-2.7.16"
$env:RDI_PYTHONHOME = $taskPython
$env:PYTHONHOME = $taskPython
$env:PYTHONPATH = "$taskPython;$taskPython/lib;$taskPython/DLLs;$taskPython/lib/site-packages"
$env:PATH = "$VivadoRoot/bin;$taskPython;$taskPython/DLLs;" + $env:PATH
$env:RT_LIBPATH = "$VivadoRoot/scripts/rt/data"
$env:RT_TCL_PATH = "$VivadoRoot/scripts/rt/base_tcl/tcl"
$env:SYNTH_COMMON = $env:RT_LIBPATH
$env:RDI_BUILD = 'yes'
$env:ISL_IOSTREAMS_RSA = "$VivadoRoot/tps/isl"
$taskProjectRoot = Split-Path $PSScriptRoot -Parent
$taskReports = Join-Path $taskProjectRoot 'reports/board_selftest'
New-Item -ItemType Directory -Path $taskReports -Force | Out-Null
$taskServer = $null
Push-Location $taskProjectRoot
try {
    if ($Action -eq 'Build') {
        $taskBuild = Join-Path $taskReports ('build_' + (Get-Date -Format yyyyMMdd_HHmmss))
        New-Item -ItemType Directory -Path $taskBuild | Out-Null
        & "$VivadoRoot/bin/unwrapped/win64.o/vivado.exe" -mode batch -source scripts/build_board_selftest.tcl -log "$taskBuild/build.log" -journal "$taskBuild/build.jou" -tclargs $taskProjectRoot $taskBuild
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath "$taskBuild/BUILD_PASS.txt")) { throw 'Self-test bitstream build failed.' }
        Get-FileHash -LiteralPath "$taskProjectRoot/rtl/top/davinci_board_selftest_top.v","$taskProjectRoot/constraints/davinci_board_selftest.xdc","$taskBuild/davinci_board_selftest.bit" -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_hashes.json" -Encoding utf8
        Set-Content -LiteralPath "$taskReports/latest_build.txt" -Value $taskBuild -Encoding utf8
        Write-Output "SELFTEST_BITSTREAM=$taskBuild/davinci_board_selftest.bit"
    }
    else {
        if ($Action -eq 'Program') {
            $taskBuiltDirectory = (Get-Content -LiteralPath "$taskReports/latest_build.txt" -Raw).Trim()
            $taskBuiltHashes = Get-Content -LiteralPath "$taskBuiltDirectory/build_hashes.json" -Raw | ConvertFrom-Json
            foreach ($taskHash in $taskBuiltHashes) {
                if ((Get-FileHash -LiteralPath $taskHash.Path -Algorithm SHA256).Hash -ne $taskHash.Hash) { throw "Built artifact/source changed: $($taskHash.Path)" }
            }
        }
        $taskServer = Start-Process -FilePath "$VivadoRoot/bin/unwrapped/win64.o/hw_server.exe" -ArgumentList '-s','tcp:127.0.0.1:3122','-p0','-I60' -WindowStyle Hidden -PassThru -RedirectStandardOutput "$taskReports/hw_server.stdout.log" -RedirectStandardError "$taskReports/hw_server.stderr.log"
        $taskStdout = "$taskReports/xsdb_$Action.stdout.log"
        $taskStderr = "$taskReports/xsdb_$Action.stderr.log"
        $taskXsdb = Start-Process -FilePath "$VivadoRoot/bin/unwrapped/win64.o/rdi_xsdb.exe" -ArgumentList 'scripts/board_selftest_xsdb.tcl',$Action,$taskProjectRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $taskStdout -RedirectStandardError $taskStderr
        Get-Content -LiteralPath $taskStdout,$taskStderr
        if ($taskXsdb.ExitCode -ne 0) { throw "XSDB self-test action failed: $($taskXsdb.ExitCode)" }
    }
}
finally {
    if ($null -ne $taskServer -and !$taskServer.HasExited) { Stop-Process -Id $taskServer.Id -ErrorAction SilentlyContinue }
    Pop-Location
}
