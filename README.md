# MotionJPEG

在正点原子达芬奇 FPGA（`xc7a35tfgg484-2`）上实现的纯 FPGA 实时 JPEG/MJPEG 视频编码系统：OV5640 摄像头采集 → 板内预处理与压缩 → USB 回传 → 主机接收显示。采集、图像处理、JPEG 编码和传输全部在 PL 内完成，不使用 ARM；主机只负责接收、解码和显示。

发布版本 **2.0.0**（初始基线 [1.0.0](https://github.com/R1ezzTa/MotionJPEG/tree/1.0.0)）：真实 OV5640 摄像头链路，1080p30 实板稳态零丢帧。

## 当前状态

主工程为**无 DDR3 的独立 JPEG 图像链路**，构建入口 `mjpeg/scripts/run_camera_build.ps1`，顶层 `davinci_mjpeg_camera_top`。设计说明与最终验证记录见 [无 DDR3 图像链路](mjpeg/docs/无DDR3图像链路.md)。

| 项目 | 能力 |
| --- | --- |
| 输入 | OV5640 单路 RAW8（DVP），板内 BGGR→YUV422 转换 |
| 压缩 | 逐帧独立 Baseline JPEG，1080p30 |
| 预处理 | 彩色 / 灰度 / 二值化 / Sobel 边缘四模式，两个 0~255 阈值板载按完整帧生效 |
| 降噪 | 稳健降噪 v2：YCbCr 3×3 中值混合 + 两级亮度引导色度平滑，强度 0~255 可调，可关闭 |
| 质量 | Q60 / Q75 / Q85 板载按键实时切换 |
| 传输 | FT232H 同步 FT245 USB，MBLK 大块封包 |
| 主机 | PC 查看器实时显示，按钮与板载按键联动控制 |

最新上板固件 `full_20260929_170515`：LUT **74.92%**、FF **46.95%**、BRAM **72%**、DSP **51.11%**；[3480 帧独立解码验收](mjpeg/reports/camera/acceptance_20260929/summary.json)，1080p30、零 FIFO 溢出。1080p30 场景 JPEG 带宽相对 RAW8 输入降低 **73.87%**。

已知待评估项：残余冷色、暗光噪声与完整色彩校准（见 [RAW 偏色定位与修正](mjpeg/docs/RAW偏色定位与修正.md)）。

## 板载与主机交互

- 按键（经用户现场确认）：KEY0 启停，KEY1 切换 Q60/Q75/Q85，KEY2 补光约 2 秒，KEY3 停止并关灯，LED 指示状态；详细映射见 [板载按键摄像头控制](mjpeg/docs/板载按键摄像头控制.md)。
- [PC 查看器](mjpeg/host/camera_viewer.py) 的"开启传输／停止传输"按钮与 KEY0 联动，停止后保持连接并显示板卡实际状态；操作说明见 [主机 README](mjpeg/host/README.md)。
- 降噪实现与新实板验收见 [板内稳健降噪](mjpeg/docs/板内稳健降噪.md)。首版 RGB sigma 方案压缩率虽降但用户未见画质改善，保留为历史记录——不以压缩率代替画质评价；相关探索见 [板内自适应阈值](mjpeg/docs/板内自适应阈值.md) 与 [DDR3 参考缓存](mjpeg/docs/DDR3参考缓存.md)。

## 快速开始

环境：Vivado 2020.1（默认安装目录 `F:/Xilinx/Vivado/2020.1`，可用 `-VivadoRoot` 指定）；主机 Python 3，参考生成需 NumPy 与 Pillow，USB 回读需 FTDI D2XX 驱动。

```powershell
# 导入板级测试源并跑同步 FIFO 回归仿真
./mjpeg/scripts/run_import.ps1 -BoardTest
./mjpeg/scripts/run_sync_fifo_sim.ps1

# 构建并下载摄像头固件（综合→实现→bit→JTAG 编程）
./mjpeg/scripts/run_camera_build.ps1 -Action Full
```

主机侧接收与验收程序、逐档测试命令见 [mjpeg README](mjpeg/README.md) 与各测试文档。上板验证在 Windows 完成，Ubuntu 接收路径尚未实际验证。

## 工程结构

- [mjpeg](mjpeg/README.md)：达芬奇 Vivado 板级工程、RTL、引脚约束、主机程序和上板测试。
- [xilinx_mjpeg](xilinx_mjpeg/README.md)：Xilinx 移植基线、独立 JPEG 整数参考模型和仿真向量；达芬奇的参考生成脚本依赖此目录。

关键文档索引：[无 DDR3 图像链路](mjpeg/docs/无DDR3图像链路.md) · [板内图像预处理](mjpeg/docs/板内图像预处理.md) · [板内稳健降噪](mjpeg/docs/板内稳健降噪.md) · [OV5640 渐进验收](mjpeg/docs/OV5640渐进验收.md) · [MJPEG 接口](mjpeg/docs/MJPEG接口.md) · [压缩核流水链路图](mjpeg/docs/压缩核流水链路图.svg) · [模块连接图](mjpeg/docs/模块连接图.svg)。

仓库保留源代码、Vivado 工程、测试数据、报告摘要与样图；Vivado 缓存、bitstream、仿真生成物、USB 原始抓包与逐帧转储保留在本地，由 `.gitignore` 排除。

## 验证方法

所有功能版本均以独立 CPU 整数 JPEG 模型为黄金参考：实板输出逐字节比对 + Pillow 完整解码 + 帧号/时间戳/计数一致性检查，证据目录含源码与 bit 流哈希。方法与口径详见各测试文档。

## 版本历史

| 版本 | 主题 | 1080p 实测 | 记录 |
| --- | --- | --- | --- |
| 1.0.0 | 模拟输入全链路贯通 | 0.666 fps | [分辨率渐进上板测试](mjpeg/docs/分辨率渐进上板测试.md) |
| 1.1.0 | 传输与供给优化（大块封包→单周期→同步 FIFO） | 21.605 fps | 见下方轨迹 |
| 1.2.0 | MMCM 100 MHz 编码时钟 | **43.209 fps** | [100 MHz 编码时钟升级](mjpeg/docs/100MHz编码时钟升级.md) |
| 2.0.0 | 真实 OV5640 摄像头（无 DDR3 链路） | 1080p30 零丢帧 | [无 DDR3 图像链路](mjpeg/docs/无DDR3图像链路.md) |

1.0.0 完成链路打通：LED/按键自测、模拟摄像头上板、实时帧率与数码管，三档共 199 帧逐字节一致。此后吞吐轨迹为：大块封包 4.010（[记录](mjpeg/docs/大块封包与链路瓶颈分析.md)）→ 单周期像素 15.239（[记录](mjpeg/docs/单周期像素输入优化.md)）→ 同步 FT245 21.605（[记录](mjpeg/docs/同步FIFO与跨时钟缓冲.md)）→ 100 MHz 43.209 fps。各阶段均含独立编码核仿真对照（如 50 MHz 无背压 23.568 fps）与停止归零、积压恢复等异常路径验证。
