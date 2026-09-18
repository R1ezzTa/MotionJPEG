# Xilinx MJPEG 移植基线

目标：纯 FPGA 完成图像采集、预处理、JPEG 编码和传输，Ubuntu 主机承担重组、显示、录像及可选识别；不开发 ARM 应用。板卡比较与系统划分见 [板卡选型与实施方案](docs/板卡选型与实施方案.md)。

用户现已确认只有领航者 7010。当前实施建议见 [领航者 7010 方案](docs/领航者7010实施方案.md)：先评估一份编码器、PL 网口及单路采集闭环，建议从 VGA30 联调、再评估 720p30。原双路 1080p60 是原方案目标，尚未由用户确认改为单路验收。

7010 单路实际综合：10,160 LUT（57.73%）、16,223 FF（46.09%）、24.5 BRAM Tile（40.83%）、42 DSP（52.50%）；100 MHz 综合后内部 WNS +2.083 ns。模块级结果支持继续评估单路系统，完整板级布局布线、CDC、网口和相机测试尚未完成。

本目录由 `F:/zju/qiansai_FPGA/jpeg_encoder` 的 2026-09-17 工作区复制而来，包含 1.0.1 之后的未发布时序优化。原工程未改动；复制时的文件清单与 SHA-256 见 `source_snapshot.json`。

## 当前边界

- 现有 JPEG/MJPEG 算法、双通道控制、仿真测试与参考数据已保留。
- `line_group_ram` 默认采用 Vivado 的 `ram_style="block"` 推断；保留原 ERAM 的 2 次幂物理深度、有效地址位和单拍读取行为。
- 添加 XSIM 回归与指定器件的 OOC（独立模块）综合入口，无需安路仿真库。
- 摄像头接收、预处理、跨时钟 FIFO、以太网 MAC/UDP、DDR 调度和板级约束尚未接入。本目录还不是可下载的整板工程。
- `mjpeg_synth_top` 是模块级综合顶层，其中宽总线用于内部连接，不能将这些端口直接分配到板卡引脚。
- `docs/MJPEG接口.md` 是原工程接口说明；其中安路历史时序与物理验证不代表本次 Xilinx 移植结果。

本次验证详情见 [移植验证记录](docs/移植验证记录.md)。先前双路 OOC 综合在 A35T 上已出现 LUT 超限，在 7020 上占用约 39% LUT、35% BRAM、38% DSP。这是板卡比较证据；后续以用户现有的 7010 为目标。尚未通过 Xilinx 200 MHz 物理时序。

## 复现

在本目录打开 PowerShell。脚本默认使用 `F:/Xilinx/Vivado/2020.1`，可用 `-VivadoRoot` 覆盖。每次构建复制到独立临时目录，避免老版本工具的中文路径问题；构建目录由脚本打印。

```powershell
./scripts/run_simulation.ps1 -Top tb_mjpeg_board
python ./scripts/verify_mjpeg.py mjpeg_board

./scripts/run_simulation.ps1 -Top tb_mjpeg_wide
python ./scripts/verify_mjpeg.py mjpeg_wide

./scripts/run_simulation.ps1 -Top tb_mjpeg_fhd
python ./scripts/verify_mjpeg.py mjpeg_fhd

# 当前 7010 单路资源评估，100 MHz 时钟在综合前加载。
./scripts/run_synthesis.ps1 -Part xc7z010clg400-1 -Channels 1 -MaxWidth 1280 -PeriodNs 10

# 历史比较器件的复现命令；重新运行可能因约束加载时机而改变结果。
./scripts/run_synthesis.ps1 -Part xc7z020clg400-2 -Channels 2
./scripts/run_synthesis.ps1 -Part xc7a35tfgg484-2 -Channels 2
```

解码复核需要 Python 和 Pillow。Vivado 综合的 Python 2 环境只用于该 PowerShell 进程；建议通过单独的 PowerShell 进程运行综合，避免影响同一终端随后运行的 Python 3。Xilinx 的布局布线、200 MHz 时序和板上吞吐仍需分别验证。综合完成标记只证明该步骤完成，不表示资源或 DRC 一定通过。完整 FHD 回归耗时较长；本次仅保留首对完成帧的部分验证证据，未将完整六帧回归标记为通过。

## 集成注意

保持双路 16 位 YUYV 接口，低字节为 Y，高字节为交替 Cb/Cr。下游反压时，数据与 SOF/EOL/EOF 等旁带必须一起保持。真实相机不能由 `ready` 直接暂停，必须配置采集缓存与整帧异常恢复。

系统整合优先使用 `mjpeg_encoder` 的内部 128 位带标签接口，重新聚合成网络包。现有 `mjpeg_synth_top` 的 32 位小包协议仅用于回归和接口调试；`m_packet_last` 是小包尾，不是 JPEG 帧尾，也不能直接当作最终网络层的帧结束信号。

Ubuntu 接收端目前只有继承的总线采样解析器 `scripts/mjpeg_receiver.py`，并未实现在线 UDP 接收和 GUI。后续应共享通道号、帧号、帧描述和错误语义，另加网络分片重组。
