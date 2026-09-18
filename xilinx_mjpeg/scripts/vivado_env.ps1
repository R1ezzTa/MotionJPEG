param([string]$VivadoRoot = 'F:/Xilinx/Vivado/2020.1')
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath "$VivadoRoot/bin/unwrapped/win64.o/xvlog.exe")) {
    throw "Vivado installation not found: $VivadoRoot"
}
$env:XILINX_VIVADO = $VivadoRoot
$env:RDI_DATADIR = "$VivadoRoot/data"
$env:RDI_APPROOT = $VivadoRoot
$env:HDI_APPROOT = $VivadoRoot
$env:XILINX = $VivadoRoot
$env:RDI_BINROOT = "$VivadoRoot/bin"
$env:RDI_BINDIR = "$VivadoRoot/bin"
$env:RDI_LIBDIR = "$VivadoRoot/lib/win64.o"
$env:RDI_PLATFORM = 'win64'
$env:RDI_OPT_EXT = '.o'
$env:RDI_BASEROOT = Split-Path $VivadoRoot -Parent
$env:TCL_LIBRARY = "$VivadoRoot/tps/tcl/tcl8.5"
$env:RDI_JAVAROOT = "$VivadoRoot/tps/win64/jre9.0.4"
$env:PATH = "$VivadoRoot/lib/win64.o;$VivadoRoot/lib/win64.o/Default;$VivadoRoot/tps/win64/jre9.0.4/bin/server;$VivadoRoot/tps/win64/jre9.0.4/bin;$VivadoRoot/tps/mingw/6.2.0/win64.o/nt/bin;$VivadoRoot/tps/mingw/6.2.0/win64.o/nt/libexec/gcc/x86_64-w64-mingw32/6.2.0;" + $env:PATH
