# MJPEG 模拟摄像头上板测试

本测试使用达芬奇 XC7A35T-FGG484-2 的 50 MHz 时钟，在 FPGA 上运行当前单通道 MJPEG 编码器。板内 ROM 提供光栅 YUYV 像素及 SOF/EOL/EOF，替代摄像头在编码器输入边界处的输出。JPEG 编码算法 RTL 沿用已复制的版本。

链路：像素 ROM → `mjpeg_synth_top(CHANNELS=1, MAX_WIDTH=1920)` → 原有 JPEG 编码器、通道控制、仲裁和封包 → FT245 异步 FIFO 调试传输 → USB_SLAVE FT232H → 主机解包、参考文件比对、Pillow 解码。

## 测试图案

每次主机发送 ASCII `G`，板卡执行以下三种图案，重复三轮，共输出九帧；重新发送 `G` 可再运行一组。每帧重新加载其量化表，覆盖配置更新、灰度和彩色切换、帧号递增及受阻时的输出握手。

2026-09-18 增加 `C` 连续模式、`S` 帧边界停止、板内每秒统计和数码管压缩帧率显示。统计口径、传输协议与连续测试命令见 [实时帧率与数码管](实时帧率与数码管.md)。

| 图案 | 尺寸 | 模式 | 参考 JPEG 字节数 |
| --- | --- | --- | --- |
| gray_ramp | 16×16 | 灰度 | 622 |
| color_noise | 32×24 | YCbCr 4:2:2 彩色 | 1752 |
| color_flat | 16×8 | YCbCr 4:2:2 彩色 | 615 |

`data/board_test/pixels.mem` 和 `quant.mem` 按上述顺序合并自相邻 `xilinx_mjpeg/data` 的既有测试向量。参考 JPEG 只供主机比对；不会烧入 FPGA 或用于板卡输出，板上码流由编码器实时生成。

## USB 接法和限制

使用当前已连接的 USB_SLAVE，FT232H 数据芯片序列号 FTB7MA1D，沿用其 EEPROM 配置的 FT245 异步 FIFO 模式。EEPROM 首字读取为 0x0011。虽然驱动显示 COM3，芯片并非 UART 引脚模式；初次尝试 UART 引脚回读没有响应，因此最终设计改用实际 FIFO 引脚。JTAG 使用已识别的 Digilent JTAG-HS1，序列号 210512180081。无需额外串口线或 ARM，不写 FT232H EEPROM，也不固化 FPGA Flash。

USB_SLAVE 的 ADBUS[7:0] 为双向数据总线，RXF#/TXE# 为经过双级同步的状态输入，RD#/WR# 控制读写和总线方向。50 MHz 下的数据建立时间为 40 ns，RD#/WR# 低脉宽为 80 ns，恢复及换向时间至少 80 ns，保守满足 FT232H 异步 FIFO 时序。异步读取的稳定窗口及外部异步总线不属于本 FPGA 内部时序报告的验证范围；测试台另行检查脉宽、数据建立和换向。生产用高速同步 FIFO 控制器仍待实现。

响应以四字节 `MJBT` 开始；之后每个原有 32 位传输字序列化为五字节：四字节小端数据和一字节 flags。JPEG 总线记录的 flags[2:0] 为有效字节数，flags[3] 为 `m_packet_last`，其余位为零。`m_packet_last` 表示封包结束；整帧由原有接收器通过末尾描述符完成重组。新版本会在完整记录之间插入 flags=0x80–0x85 的帧率快照，空闲期间也发送；当前接收程序自动识别并剥离这些记录。

## 重跑

在 HDL 工作区的 PowerShell 中：

```powershell
./mjpeg/scripts/run_mjpeg_board_test.ps1 -Action Build
./mjpeg/scripts/run_mjpeg_board_test.ps1 -Action Program
python ./mjpeg/host/board_test_receiver.py --ftdi --sessions 3 --output ./mjpeg/reports/mjpeg_board_test/hardware_new
```

生成文件的绝对位置记录在 `reports/mjpeg_board_test/latest_build.txt`。下载工具校验构建时的源文件、向量、约束和 bitstream 哈希；板卡型号、JTAG 序列号和 IDCODE 匹配后才下载。只通过 JTAG 临时配置 FPGA。

接收程序需 Python 3.10+、Pillow 和 FTDI D2XX 运行库；Windows 当前驱动已提供 ftd2xx.dll。D2XX 仅选择序列号 FTB7MA1D 的数据接口；FT_SetBitMode(reset) 恢复 EEPROM 选择的异步 FIFO 模式，不编程 EEPROM。程序启动时预期首帧 ID 为零。重新运行主机接收程序前，按一下板上的 RESET，使帧号归零；不要在传输期间复位。LED0 表示量化表就绪，LED1 表示测试运行，LED2 表示一组九帧已全部写入 USB FIFO，LED3 表示错误。

Ubuntu 主机同样可接收。安装 Pillow 和官方 Linux D2XX 运行库，按运行库 README 配置设备访问，再将 USB_SLAVE 接到 Ubuntu：

```bash
python3 -m pip install pillow
python3 mjpeg/host/board_test_receiver.py --ftdi --library /usr/local/lib/libftd2xx.so --sessions 3 --output mjpeg/reports/mjpeg_board_test/ubuntu_capture
```

以实际运行库路径替换 `--library`。本次实际硬件回读在 Windows 上进行，Ubuntu 命令尚未实机验证。复位后三次主机请求共验证 27 帧；保存 USB 原始数据、总线 CSV、JPEG、解码 PNG 和帧元数据。`--port` 的 pyserial 后端仍保留，但不可据此假设板载 FT232H 使用 UART 引脚模式。

## 工程和仿真

`mjpeg.xpr` 已加入板级顶层、UART、ROM 数据、实际引脚约束和测试台。重新载入板级配置可运行 `scripts/run_import.ps1 -BoardTest`，或在已打开工程的 Tcl Console 中 source `scripts/activate_mjpeg_board_test.tcl`。原来的模块级导入工具仍可用来切回编码器分析顶层。

完整异步 FIFO 仿真命令为 `scripts/run_mjpeg_board_sim.ps1`，模拟两次 `G` 请求、18 帧，包含周期性 TXE# 阻塞和长暂停，检查数据建立时间、RD#/WR# 脉宽和总线换向。随后运行：

```powershell
python ./mjpeg/host/board_test_receiver.py --capture ./mjpeg/reports/mjpeg_board_test/simulation_fifo/usb_capture.bin --sessions 2 --output ./mjpeg/reports/mjpeg_board_test/simulation_fifo_verified
```

## 验证边界

模拟像素源遵守 ready/valid，可暂停；真实 DVP 摄像头通常不能随编码器停顿，仍需要采集、时钟域处理和足够的缓存。本测试不覆盖摄像头引脚、SCCB 配置、DDR、高速 USB FIFO或 1080p60 的性能。保留最大行宽 1920 的编码配置不等于实测 1920 像素帧或全高清帧率。

通过标准是：路由后内部 setup/hold 时序通过且 DRC 无错误、实际 JTAG 配置成功、主机从板卡接收九帧连续组、元数据与帧序号有效、每帧 JPEG 字节与参考完全一致、全部能独立解码。当前算法保留已有的 RAM 异步复位控制和 DSP 流水线 DRC 警告；本次不验证传输中复位的恢复行为。

## 本次结果

2026-09-17 实际达芬奇板卡上板通过。

- 最终 bitstream：`reports/mjpeg_board_test/build_20260917_234814/davinci_mjpeg_board_test.bit`，1,631,770 字节。
- 50 MHz 路由后内部 WNS +9.075 ns、WHS +0.055 ns；DRC 0 错误、66 警告，包含已有 DSP 流水线建议和 RAM 异步控制警告，未隐藏或降低违规等级。
- 路由后资源：10,042 LUT（48.28%）、16,234 FF（39.02%）、26 BRAM（52%）、42 DSP（46.67%）。
- JTAG 配置：实际 XC7A35T、已识别 HS1 线缆，CRC ERROR=0、DONE PIN=1、EOS=1。
- 异步 FIFO 完整仿真：两次请求、18 帧，包含 FIFO 阻塞、数据建立、脉宽及总线换向检查；全部 JPEG 与参考逐字节相同并能解码。
- USB_SLAVE 真实硬件回读：三次请求、27 帧，帧 ID 0–26，全部 status=0、元数据有效、时间戳严格递增；全部 JPEG 与 CPU 参考字节一致且 Pillow 解码成功。总 JPEG 数据 26,901 字节，原始 USB 调试数据 348,582 字节。
- 原复制基线的 19 个 `.v` 和 3 个 `.vh` 哈希仍全部相同，编码器算法未修改。

实物结果位于 `reports/mjpeg_board_test/hardware_fifo_20260917/`：`VERIFY_PASS.txt`、`frames.json`、`run_evidence.json`、`ftdi_info.json`、`usb_capture.bin`、各组总线 CSV、27 个 JPEG 及解码 PNG。`decode_preview.jpg` 为板上前三帧解码后的放大预览。构建目录另有 `BUILD_PASS.txt`、`PROGRAM_PASS.txt`、`HARDWARE_JPEG_PASS.txt`、源文件/下载文件 SHA-256 清单及路由报告。

工程使用异步 FIFO 板级顶层。一组完成后 LED0 和 LED2 亮，LED1 和 LED3 灭；重新运行接收程序前复位使帧号归零。当前板上配置已更新为带实时帧率和数码管的版本，其新增结果另见上述文档。它仍是功能原型，不能据此宣称真实摄像头、高速同步 USB 或全高清帧率通过。
