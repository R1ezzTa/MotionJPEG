# 达芬奇 MJPEG 工程

版本：**1.2.0**。本版使用 100 MHz 编码和封包时钟、60 MHz 同步 FT245 及跨时钟 FIFO。

板卡：正点原子达芬奇 FPGA，器件 `xc7a35tfgg484-2`。FPGA 承担采集、处理和 JPEG 编码，Ubuntu 主机承担接收、解码、显示和应用；不开发 ARM 部分。

## 目录

```text
mjpeg/
├── mjpeg.xpr             Vivado 工程
├── rtl/
│   ├── top/              MJPEG 模拟摄像头上板测试、LED/按键自测顶层
│   ├── camera/           DVP 采集、摄像头配置，待实现
│   ├── preprocess/       像素预处理，待实现
│   ├── usb/              FT245 同步 FIFO、跨时钟缓冲；保留异步控制器
│   ├── memory/           DDR 控制和缓存调度，待实现
│   ├── common/           行缓存 RAM、JPEG 输出缓存
│   ├── core/             JPEG 编码核心
│   │   ├── frontend/     光栅像素转 MCU / 8×8 块
│   │   ├── dct/          定点 DCT
│   │   ├── quant/        量化
│   │   ├── entropy/      Zigzag、符号、Huffman、比特打包
│   │   └── format/       JPEG 文件格式组装
│   ├── video/            通道控制、仲裁、调试分包
│   └── generated/        3 个 .vh 表文件
├── constraints/          MJPEG 上板测试及 LED 自测的引脚、时钟约束
│   └── reference/        官方完整引脚表，仅供查阅
├── tb/                   同步/异步 FIFO、CDC 和 MJPEG 板级仿真
├── data/board_test/      模拟摄像头像素、量化表、主机参考 JPEG
├── ip/                   后续时钟、FIFO、MIG 等 IP
├── host/                 Windows / Ubuntu 回读、解包和 JPEG 校验程序
├── scripts/              Vivado 源文件导入工具
├── docs/                 接口说明、复制清单、工程备份
└── reports/              检查及后续构建报告
```

Vivado 自动生成的 `mjpeg.cache`、`mjpeg.hw`、`mjpeg.sim` 等目录继续由工具管理。

## 已复制的代码

19 个 `.v` 和 3 个依赖 `.vh` 来自相邻的 `../xilinx_mjpeg/rtl`，保留原目录及 include 路径。全部逐文件 SHA-256 比较一致；本次没有修改算法 RTL。该基线已将行缓存 RAM 适配为 Vivado block RAM 推断，默认不启用安路原语分支。

复制来源和校验值：`docs/copied_rtl_manifest.json`。原始工程快照：`docs/original_source_snapshot.json`。通道、配置和数据接口详见 `docs/MJPEG接口.md`，其中历史安路性能记录不代表达芬奇上板性能。

当前工程顶层为 `davinci_mjpeg_board_test_top`，内部使用 `mjpeg_synth_top(CHANNELS=1, MAX_WIDTH=1920)`。板内 ROM/渐进发生器模拟摄像头，USB_SLAVE 默认采用 FT232H 同步 FIFO 和跨时钟缓冲，不开发 ARM。原方案双路 1080p60 尚未在该板卡实现。

已增加板内一秒窗口计数：六位数码管显示成功压缩帧率，USB 同步报告输入、成功和失败帧率及累计数。主机 `--live --duration 60` 可连续模拟图像并观察数码管，结束后自动停止并验证归零。使用方法和计数口径见 [实时帧率与数码管](docs/实时帧率与数码管.md)。

2026-09-18 这版固件已实际上板，累计验证 16,526 帧 JPEG，连续模式统计与实际帧数一致，停止后帧率归零。最终短时实测小图压缩吞吐为 210–221 fps；数码管驱动已通过仿真，现场显示外观待确认。

随后完成完整分辨率渐进上板：640×480 验证 134 帧（4.450 fps）、1280×720 验证 45 帧（1.478 fps）、1920×1080 验证 20 帧（0.666 fps），共 199 帧全部与独立参考一致且能解码。当前固件使用实时像素发生器，支持 V/H/F 三档连续测试、每帧耗时与 END1 停止标记，继续保留 G/C 小图模式和数码管。实测吞吐主要受当前调试传输链路限制。报告、样图和重跑命令见 [分辨率渐进上板测试](docs/分辨率渐进上板测试.md)。

## 已完成的板卡自测

已另行建立 LED / KEY0 / RESET 自测设计，完成 50 MHz 布局布线（WNS +16.803 ns、WHS +0.121 ns）、零 DRC 违规，并于 2026-09-17 经 JTAG 下载到实际 A35T。配置状态显示 DONE=1、EOS=1、CRC ERROR=0。用户现场确认 LED0/1 每 0.5 秒交替、LED3 常亮、LED2 响应 KEY0、按住 RESET 时四灯熄灭，全部符合预期，基础上板自测通过。

自测代码、独立构建/下载命令、下载文件和结果边界见 [达芬奇上板自测](docs/达芬奇上板自测.md)。它验证板卡基础链路，不代表摄像头 / JPEG / USB 完整系统已经通过。

## MJPEG 模拟摄像头上板结果

2026-09-17 已将现有 MJPEG 编码器实际下载到达芬奇，ROM 模拟三种摄像头图案，经 USB_SLAVE 异步 FIFO 回读 27 帧；全部与参考 JPEG 逐字节一致并能解码。50 MHz 路由后 WNS +9.075 ns、WHS +0.055 ns，DRC 0 错误（保留 66 个已有流水线和 RAM 异步控制警告）。实际资源为 48.28% LUT、52% BRAM、46.67% DSP。详情、输出图像和重跑命令见 [MJPEG模拟摄像头上板测试](docs/MJPEG模拟摄像头上板测试.md)。

## 工程导入方式

板级工程通过 `scripts/activate_mjpeg_board_test.tcl` 导入 RTL、ROM 数据、板级 XDC 和测试台。原有 `scripts/import_sources.tcl` 仍可切回 `mjpeg_synth_top` 模块分析顶层。

在已经打开本工程的 Vivado Tcl Console 中执行：

```tcl
source F:/zju/dasanshangkecheng/HDL/mjpeg/scripts/activate_mjpeg_board_test.tcl
```

关闭 Vivado 工程后，也可以在 PowerShell 中运行 `./scripts/run_import.ps1 -BoardTest`。

## 当前阶段

此前的双 1 KB BRAM 大块封包和链路计数版本，采用两周期输入时实板 VGA / 720p / 1080p 为 79.955 / 26.886 / 11.977 fps。实时和仅接收两轮共 7,133 帧全部与参考相同并可解码，1080p 输入等待为零，当时主要受两周期发生器限制。大块固件的主机回读须加 `--blocks`；协议、重跑命令和计数口径见 [大块封包与链路瓶颈分析](docs/大块封包与链路瓶颈分析.md)。

此前单周期渐进像素输入的异步版本，实际 VGA / 720p / 1080p 为 101.404 / 34.177 / 15.239 fps，两轮 9,054 帧全部匹配参考并可解码；主瓶颈为 FT245 六周期异步写时序。主机可用 `--pixel-cycles 1` 强制校验每帧供给计时，缺省也能识别历史两周期抓包。证据见 [单周期像素输入优化](docs/单周期像素输入优化.md)。

上一轮同步 FT245：50 MHz 编码域、60 MHz CLKOUT 域，8 KiB TX / 256 字节 RX 双时钟 FIFO 和原子统计快照。实板 VGA / 720p / 1080p 为 **144.407 / 48.420 / 21.605 fps**，比上一版再提高约 42%；两轮 12,870 帧全部匹配参考并可解码，积压数据后重开链路的恢复测试通过。路由建立/保持裕量 +0.064/+0.008 ns，关键 CDC 和 DRC 错误为零。主机带 `--blocks --sync-fifo`，重开设备触发时钟保护复位，帧号从零开始。当前主要限制在编码域到封包模块的供给。实现、外部时序、CDC 约束和测试记录见 [同步 FIFO 与跨时钟缓冲](docs/同步FIFO与跨时钟缓冲.md)。

`1.1.0` 已完成首轮吞吐优化：JPEG 短 beat 聚合、加速 FT245 异步写周期和主机批量解析。最终上板实测 VGA 26.732 fps、720p 9.195 fps、1080p 4.010 fps，相比 1.0.0 约提高 6 倍；两轮合计 2,307 帧全部通过参考和解码验证。独立编码核在连续输入、输出始终可接收的 50 MHz 仿真条件下为 23.568 fps。实现、证据和剩余限制见 [吞吐优化记录](docs/吞吐优化记录.md)。

当前工作区进一步通过 MMCM 将编码和封包域提升为 **100 MHz**，USB 保持 60 MHz。实板 VGA / 720p / 1080p 为 **288.813 / 96.841 / 43.209 fps**；两轮 25,736 帧均匹配参考并可解码，停止归零及积压恢复通过。渐进测试和抓包回放须加 `--core-clock-hz 100000000`，时序与测试记录见 [100 MHz 编码时钟升级](docs/100MHz编码时钟升级.md)。

独立构建和下载使用 `scripts/run_mjpeg_board_test.ps1`，主机渐进测试使用 `host/progressive_test.py`，小图使用 `host/board_test_receiver.py`。初期异步结果见 [MJPEG模拟摄像头上板测试](docs/MJPEG模拟摄像头上板测试.md)。真实 DVP、SCCB 和 DDR 尚待集成。

官方 `constraints/reference/DaVinci_FPGA_IO.xdc` 保留为参考。实际板级使用 `constraints/davinci_mjpeg_board_test.xdc` 约束引脚与 USB 外部时序，`constraints/davinci_mjpeg_cdc.xdc` 在实现阶段约束内部 CDC。
