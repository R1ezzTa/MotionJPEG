# MotionJPEG

在正点原子达芬奇 FPGA（`xc7a35tfgg484-2`）上实现的单路实时 JPEG/MJPEG 系统，版本 **2.0.0**。

OV5640 RAW8 → BGGR 颜色重建 → 板内降噪与预处理 → 独立 JPEG → FT232H 同步 USB → PC 显示。采集、图像处理和编码均在 PL 内完成，无 ARM、无 DDR3 帧缓存。

## 最终功能

| 项目 | 当前实现 |
| --- | --- |
| 输入与编码 | 单路 1920×1080 RAW8、30 fps，100 MHz 编码 |
| 预处理 | 彩色、灰度、二值化、Sobel；亮度和边缘阈值各 0～255 |
| 降噪 | YCbCr 3×3 中值混合与两级亮度引导色度平滑，强度 0～255 |
| 画质 | Q60 / Q75 / Q85，整帧切换 |
| 传输 | 60 MHz 同步 FT245，跨时钟 FIFO，MBLK 大块封包 |
| 交互 | 板载四键、LED、数码管 FPS，PC 启停与设置联动 |

默认：停止、关灯、Q85、彩色、亮度阈值 128、边缘阈值 32、降噪 0。KEY0 启停，KEY1 切换画质，KEY2 补光约两秒，KEY3 停止并关灯。

最终上板基线 `full_20260929_170515` 的资源为 LUT 74.92%、FF 46.95%、BRAM 72%、DSP 51.11%；[3480 帧验收](mjpeg/reports/camera/acceptance_20260929/summary.json)通过，1080p30、零 FIFO 溢出。这里的实板数据属于精简前的最终功能基线，精简后的验证见[验证说明](mjpeg/docs/验证.md)。冷色、暗光噪声和完整色彩校准仍待评估；载荷降低不代表画质改善。

## 构建与运行

需要 Vivado 2020.1、Python 3.10+、Pillow；参考模型和测量脚本还需 NumPy。USB 使用 FTDI D2XX 驱动，GUI 使用 Tkinter。Vivado 默认目录为 `F:/Xilinx/Vivado/2020.1`，可用 `-VivadoRoot` 指定。

```powershell
# 综合、实现、生成 bitstream
./mjpeg/scripts/run_camera_build.ps1 -Action Full
# 下载本次构建（也可用 -BuildDirectory 指定目录）
./mjpeg/scripts/run_camera_program.ps1 -Action Program
# 打开 PC 查看器，点击开启传输或按 KEY0
python mjpeg/host/camera_viewer.py
```

仅综合用 `-Action Synth`。Vivado GUI 工程为 `mjpeg/mjpeg.xpr`，顶层为 `davinci_mjpeg_camera_top`；刷新源清单可运行 `mjpeg/scripts/activate_camera.tcl`。构建及编程分别执行，避免验证源码时改变板卡状态。

```powershell
python -m unittest discover -s mjpeg/tb -p 'test_*.py'
./mjpeg/scripts/run_board_controls_sim.ps1
./mjpeg/scripts/run_sync_fifo_sim.ps1
python mjpeg/host/camera_receiver.py --ftdi --duration 60 --require-fps 30 --require-no-drops --output mjpeg/reports/camera/my_acceptance
```

## 目录

- [mjpeg/rtl](mjpeg/README.md)：摄像头、JPEG 编码、控制及同步 USB；实际源集合由 `scripts/camera_sources.txt` 定义。
- [mjpeg/host](mjpeg/host/README.md)：查看器、严格接收器、预处理与降噪验收工具。
- [mjpeg/tb](mjpeg/tb/README.md)：当前功能回归、独立像素参考、JPEG 金样及同步 USB 仿真。
- [mjpeg/docs](mjpeg/docs/无DDR3图像链路.md)：当前架构、协议和验证说明。
- `mjpeg/reports/camera`：最终功能基线的构建与验收证据。

旧 DDR3、同坐标块复用、自适应阈值、首版 RGB 降噪、UART/异步 USB 顶层及过程报告已退出工作树，历史可通过 Git 查询。模拟图案保留用于独立金样回归，综合时选择真实摄像头。Vivado 生成物、原始抓包和临时文件由 `.gitignore` 排除。
