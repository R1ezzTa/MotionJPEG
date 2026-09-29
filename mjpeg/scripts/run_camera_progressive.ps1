param(
    [string]$Profiles='1,2,3,4,5',
    [int]$Duration=30,
    [string]$Python='E:/anaconda/123/python.exe',
    [string]$Library='C:/Windows/System32/DriverStore/FileRepository/ftdibus.inf_amd64_6d7e924c4fdd3111/amd64/ftd2xx64.dll'
)
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path "$PSScriptRoot/../..").Path
$taskRun=Join-Path $taskRoot ('mjpeg/reports/ov5640/progressive_'+(Get-Date -Format yyyyMMdd_HHmmss))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskModes=@(
    @{name='vga15';width=640;height=480;fps=15},
    @{name='vga30';width=640;height=480;fps=30},
    @{name='hd15';width=1280;height=720;fps=15},
    @{name='hd30';width=1280;height=720;fps=30},
    @{name='fhd15';width=1920;height=1080;fps=15},
    @{name='fhd30_raw';width=1920;height=1080;fps=30}
)
$taskResults=@()
Push-Location $taskRoot
try {
    foreach($taskProfileText in $Profiles.Split(',')){
        $taskProfile=[int]$taskProfileText
        if($taskProfile -lt 0 -or $taskProfile -gt 5){throw "Invalid profile $taskProfile"}
        $taskMode=$taskModes[$taskProfile]
        $taskStage=Join-Path $taskRun $taskMode.name
        New-Item -ItemType Directory -Path $taskStage | Out-Null
        Write-Output "PROGRESSIVE_STAGE=$($taskMode.name) BUILD_STARTED"
        # Native stderr includes harmless Vivado profiler notices. Check exit
        # codes explicitly instead of letting PowerShell wrap them as failures.
        $ErrorActionPreference='Continue'
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/run_mjpeg_board_test.ps1" -Action Build -CameraProfile $taskProfile *> "$taskStage/build_console.log"
        $taskBuildExit=$LASTEXITCODE;$ErrorActionPreference='Stop'
        if($taskBuildExit){throw "Build failed: $taskStage/build_console.log"}
        $taskBuild=(Get-Content 'mjpeg/reports/mjpeg_board_test/latest_build.txt' -Raw).Trim()
        Write-Output "PROGRESSIVE_STAGE=$($taskMode.name) PROGRAM_STARTED BUILD=$taskBuild"
        $ErrorActionPreference='Continue'
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/run_mjpeg_board_test.ps1" -Action Program *> "$taskStage/program_console.log"
        $taskProgramExit=$LASTEXITCODE;$ErrorActionPreference='Stop'
        if($taskProgramExit){throw "Program failed: $taskStage/program_console.log"}
        Write-Output "PROGRESSIVE_STAGE=$($taskMode.name) CAPTURE_STARTED"
        $ErrorActionPreference='Continue'
        & $Python mjpeg/host/camera_receiver.py --ftdi --library $Library --duration $Duration --width $taskMode.width --height $taskMode.height --target-fps $taskMode.fps --require-fps $taskMode.fps --require-no-drops --save-count 1800 --output "$taskStage/capture" *> "$taskStage/capture_console.log"
        $taskCaptureExit=$LASTEXITCODE;$ErrorActionPreference='Stop'
        $taskSummary=Get-Content "$taskStage/capture/summary.json" -Raw | ConvertFrom-Json
        $taskResults+=@{profile=$taskProfile;mode=$taskMode.name;build=$taskBuild;capture="$taskStage/capture";summary=$taskSummary}
        $taskResults | ConvertTo-Json -Depth 10 | Set-Content "$taskRun/stages.json" -Encoding utf8
        if($taskCaptureExit -or !$taskSummary.pass){throw "Stage failed: $taskStage/capture/summary.json"}
        Write-Output "PROGRESSIVE_STAGE=$($taskMode.name) PASS FPS=$($taskSummary.timestamp_fps) DECODED=$($taskSummary.decoded_frames)"
    }
} finally {Pop-Location;Write-Output "PROGRESSIVE_RUN=$taskRun"}
