# 达芬奇摄像头工程

当前工程是单路 OV5640、单路独立 JPEG、单路同步 USB。构建入口为 `scripts/run_camera_build.ps1`，编程入口为 `scripts/run_camera_program.ps1`，顶层为 `rtl/top/davinci_mjpeg_camera_top.v`。

| 目录 | 职责 |
| --- | --- |
| `rtl/board` | 板载键、USB 命令、画质及预处理设置 |
| `rtl/camera` | SCCB 初始化、DVP 捕获、RAW 转换、降噪和预处理 |
| `rtl/core` | 光栅分块、DCT、量化、Huffman 和 JPEG 格式 |
| `rtl/video` | 帧生命周期、数据缓冲和封包 |
| `rtl/usb` | 同步 FT245、异步跨时钟 FIFO、统计快照与 MBLK |
| `rtl/top` | 摄像头顶层、编码引擎、FPS 显示与回归图案源 |
| `constraints` | 当前引脚、外部时序、CDC 约束和官方引脚参考 |
| `scripts` | 当前构建、编程、源清单、参考生成与仿真入口 |
| `data` | 量化表和独立 JPEG 回归金样 |
| `tb` | 当前模块与集成测试 |
| `host` | PC 接收、显示与功能验收 |

构建固定真实 1080p30 RAW8 输入，默认保留降噪与预处理，可用 `-DenoiseEnable 0` 或 `-PreprocessEnable 0`关闭相应硬件。运行时强度为 0 即关闭滤波，无需重新构建。

架构见[无 DDR3 图像链路](docs/无DDR3图像链路.md)，接口见[MJPEG 接口](docs/MJPEG接口.md)，验证见[验证说明](docs/验证.md)，主机用法见[host README](host/README.md)。

JPEG 核最初由 Xilinx 移植基线复制并进一步优化，原移植目录已删除。来源及校验值保存在 `docs/copied_rtl_manifest.json` 和 `docs/original_source_snapshot.json`；这些文件记录初始来源，当前源集合使用 `scripts/camera_sources.txt`。
