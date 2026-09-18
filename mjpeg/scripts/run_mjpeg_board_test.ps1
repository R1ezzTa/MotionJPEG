param(
    [ValidateSet('Build','Help','Program','State')][string]$Action = 'Build',
    [string]$VivadoRoot = 'F:/Xilinx/Vivado/2020.1',
    [string]$SynthesisBuild = ''
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
$taskReports = Join-Path $taskProjectRoot 'reports/mjpeg_board_test'
New-Item -ItemType Directory -Path $taskReports -Force | Out-Null
$taskServer = $null
Push-Location $taskProjectRoot
try {
    if ($Action -eq 'Build') {
        $taskBuild = Join-Path $taskReports ('build_' + (Get-Date -Format yyyyMMdd_HHmmss))
        New-Item -ItemType Directory -Path $taskBuild | Out-Null
        $taskSourceFiles=@((Get-ChildItem "$taskProjectRoot/rtl" -File -Recurse).FullName + (Get-ChildItem "$taskProjectRoot/data/board_test" -File).FullName + "$taskProjectRoot/constraints/davinci_mjpeg_board_test.xdc" + "$taskProjectRoot/constraints/davinci_mjpeg_cdc.xdc")
        $taskSourceHashes=Get-FileHash -LiteralPath $taskSourceFiles -Algorithm SHA256
        $taskSourceHashes | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_input_hashes.json" -Encoding utf8
        $taskTclArgs=@($taskProjectRoot,$taskBuild)
        $taskCheckpointHash=$null
        if($SynthesisBuild){
            $taskReuseRoot=(Resolve-Path -LiteralPath $SynthesisBuild).Path
            $taskReuseHashes=Get-Content -LiteralPath "$taskReuseRoot/build_input_hashes.json" -Raw | ConvertFrom-Json
            if($taskReuseHashes.Count -ne $taskSourceHashes.Count){
                throw 'Cannot reuse synthesis: source file set changed'
            }
            # A synthesis checkpoint may be reused only when all netlist inputs
            # match; implementation-only CDC constraints are reapplied afresh.
            $taskCdcPath=(Get-Item -LiteralPath "$taskProjectRoot/constraints/davinci_mjpeg_cdc.xdc").FullName
            foreach($taskHash in $taskSourceHashes){
                if($taskHash.Path -eq $taskCdcPath){continue}
                $taskOldHash=@($taskReuseHashes | Where-Object {$_.Path -eq $taskHash.Path})
                if($taskOldHash.Count -ne 1 -or $taskOldHash[0].Hash -ne $taskHash.Hash){
                    throw "Cannot reuse synthesis: source mismatch $($taskHash.Path)"
                }
            }
            $taskCheckpointHash=Get-FileHash -LiteralPath "$taskReuseRoot/synthesized.dcp" -Algorithm SHA256
            $taskCheckpointHash | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/reused_synthesis.json" -Encoding utf8
            $taskTclArgs+=@($taskCheckpointHash.Path)
        }
        & "$VivadoRoot/bin/unwrapped/win64.o/vivado.exe" -mode batch -source scripts/build_mjpeg_board_test.tcl -log "$taskBuild/build.log" -journal "$taskBuild/build.jou" -tclargs @taskTclArgs
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath "$taskBuild/BUILD_PASS.txt")) { throw 'Self-test bitstream build failed.' }
        if($taskCheckpointHash -and (Get-FileHash -LiteralPath $taskCheckpointHash.Path -Algorithm SHA256).Hash -ne $taskCheckpointHash.Hash){
            Remove-Item -LiteralPath "$taskBuild/BUILD_PASS.txt"
            throw 'Reused synthesis checkpoint changed during build'
        }
        foreach($taskHash in $taskSourceHashes){
            if((Get-FileHash -LiteralPath $taskHash.Path -Algorithm SHA256).Hash -ne $taskHash.Hash){
                Remove-Item -LiteralPath "$taskBuild/BUILD_PASS.txt"
                throw "Source changed during build: $($taskHash.Path)"
            }
        }
        Get-FileHash -LiteralPath @($taskSourceFiles + "$taskBuild/davinci_mjpeg_board_test.bit") -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath "$taskBuild/build_hashes.json" -Encoding utf8
        [System.IO.File]::WriteAllText("$taskReports/latest_build.txt", $taskBuild + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        Write-Output "MJPEG_TEST_BITSTREAM=$taskBuild/davinci_mjpeg_board_test.bit"
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
        $taskXsdb = Start-Process -FilePath "$VivadoRoot/bin/unwrapped/win64.o/rdi_xsdb.exe" -ArgumentList 'scripts/mjpeg_board_test_xsdb.tcl',$Action,$taskProjectRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $taskStdout -RedirectStandardError $taskStderr
        Get-Content -LiteralPath $taskStdout,$taskStderr
        if ($taskXsdb.ExitCode -ne 0) { throw "XSDB self-test action failed: $($taskXsdb.ExitCode)" }
    }
}
finally {
    if ($null -ne $taskServer -and !$taskServer.HasExited) { Stop-Process -Id $taskServer.Id -ErrorAction SilentlyContinue }
    Pop-Location
}

