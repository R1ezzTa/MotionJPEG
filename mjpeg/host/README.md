# MJPEG 主机接收与验证

使用 Python 3.10 或更新版本、Pillow 和 FTDI D2XX。`ftdi_fifo.py` 在 Windows 默认加载 `ftd2xx.dll`，在 Ubuntu 默认加载 `libftd2xx.so`，可用 `--library` 指定绝对路径。Windows 已完成实际回读；Ubuntu 路径尚待实机验证。

当前 100 MHz 同步固件必须带 `--blocks --sync-fifo`，渐进测试及其抓包回放还须加 `--core-clock-hz 100000000`（默认 50 MHz 仅用于历史抓包），通过 `block_records.py` 解析 1 KB JPEG 数据块、帧描述符、FPS、帧计时和 USB 控制器计数。此前异步大块固件只带 `--blocks`；原 1.0.0/1.1.0 固件使用默认旧协议。

当前编码和封包域 100 MHz，USB 60 MHz；升级结果见 [100 MHz 编码时钟升级](../docs/100MHz编码时钟升级.md)。渐进源为一周期一个像素，测试可加 `--pixel-cycles 1` 强制核对；旧渐进固件可加 `--pixel-cycles 2`。缺省识别每档全部帧一致的一/两周期节奏。同步链路及运行方法见 [同步 FIFO 与跨时钟缓冲](../docs/同步FIFO与跨时钟缓冲.md)，此前异步结果见 [单周期像素输入优化](../docs/单周期像素输入优化.md)。

```powershell
# 各尺寸连续 30 秒，接收时逐帧比较参考并解码。
python mjpeg/host/progressive_test.py --ftdi --blocks --sync-fifo --pixel-cycles 1 --core-clock-hz 100000000 --seconds 30 --output mjpeg/reports/mjpeg_board_test/hardware_core100_live_20260918

# 仅接收保存，结束后再完整检查。同步模式每次重开设备会复位测试计数。
python mjpeg/host/progressive_test.py --ftdi --blocks --sync-fifo --pixel-cycles 1 --core-clock-hz 100000000 --receive-only --seconds 30 --output mjpeg/reports/mjpeg_board_test/hardware_core100_receive_20260918
python mjpeg/host/progressive_test.py --capture mjpeg/reports/mjpeg_board_test/hardware_core100_receive_20260918/usb_capture.bin --blocks --sync-fifo --pixel-cycles 1 --core-clock-hz 100000000 --output mjpeg/reports/mjpeg_board_test/hardware_core100_receive_20260918/verified_offline

# 原有三种小图案测试仍可用。
python mjpeg/host/board_test_receiver.py --ftdi --blocks --sync-fifo --sessions 3 --output mjpeg/reports/mjpeg_board_test/hardware_core100_small
```

每次 FPGA 重新配置或同步主机程序重新打开设备后帧号从零开始，同一进程内保持连续。历史异步固件未重新配置时用 `--first-id` 接续帧号。仅接收模式的 CAPTURE_PASS 不代表 JPEG 验证完成；离线回放逐字节比较参考、解码成功后才生成 VERIFY_PASS。

结果保存在各尺寸目录的 `result.json`、`frames.json`、`timings.json`、`fps.json` 和 `link_windows.json`；原始 `usb_capture.bin` 可重新回放。链路计数及稳态窗口选取方法见 [大块封包与链路瓶颈分析](../docs/大块封包与链路瓶颈分析.md)。
