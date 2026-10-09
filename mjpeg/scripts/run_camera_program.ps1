param(
    [ValidateSet('Program','State')][string]$Action='Program',
    [string]$VivadoRoot='F:/Xilinx/Vivado/2020.1',
    [string]$BuildDirectory=''
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/vivado_env.ps1" -VivadoRoot $VivadoRoot -Build
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskReports=Join-Path $taskRoot 'reports/camera'
New-Item -ItemType Directory -Force -Path $taskReports | Out-Null
if($Action -eq 'Program') {
    if(!$BuildDirectory){$BuildDirectory=(Get-Content "$taskReports/latest_build.txt" -Raw).Trim()}
    $BuildDirectory=(Resolve-Path -LiteralPath $BuildDirectory).Path
    foreach($taskHash in (Get-Content "$BuildDirectory/build_hashes.json" -Raw | ConvertFrom-Json)) {
        if((Get-FileHash -LiteralPath $taskHash.Path -Algorithm SHA256).Hash -ne $taskHash.Hash){
            throw "Built input changed: $($taskHash.Path)"
        }
    }
}
$taskServer=Start-Process -FilePath "$VivadoRoot/bin/unwrapped/win64.o/hw_server.exe" -ArgumentList '-s','tcp:127.0.0.1:3122','-p0','-I60' -WindowStyle Hidden -PassThru -RedirectStandardOutput "$taskReports/hw_server.stdout.log" -RedirectStandardError "$taskReports/hw_server.stderr.log"
try {
    & "$VivadoRoot/bin/unwrapped/win64.o/rdi_xsdb.exe" "$PSScriptRoot/camera_xsdb.tcl" $Action $BuildDirectory
    if($LASTEXITCODE -ne 0){throw "Camera JTAG $Action failed"}
} finally {
    if(!$taskServer.HasExited){Stop-Process -Id $taskServer.Id}
}
