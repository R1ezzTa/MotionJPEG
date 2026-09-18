# MotionJPEG

版本：**1.0.0**。

在正点原子达芬奇 FPGA（`xc7a35tfgg484-2`）上运行纯 FPGA JPEG/MJPEG 编码，主机负责接收、解码和显示。当前版本使用板内模拟图像输入，不开发 ARM 部分。

## 工程目录

- [mjpeg](mjpeg/README.md)：达芬奇 Vivado 板级工程、RTL、引脚约束、主机程序和上板测试。
- [xilinx_mjpeg](xilinx_mjpeg/README.md)：Xilinx 移植基线、独立 JPEG 参考模型和仿真向量；达芬奇参考生成脚本依赖此目录。
- [分辨率渐进上板测试](mjpeg/docs/分辨率渐进上板测试.md)：VGA、720p、1080p 的实测结果及重跑方法。

## 1.0.0 验证结果

已完成 LED/按键自测、模拟摄像头 MJPEG 上板、板内实时帧率统计与六位数码管驱动，以及完整分辨率渐进测试。三档实际板卡测试共验证 199 帧，全部与独立参考 JPEG 逐字节一致并可解码。

| 分辨率 | 验证帧数 | 实测吞吐 fps |
| --- | ---: | ---: |
| 640×480 | 134 | 4.450 |
| 1280×720 | 45 | 1.478 |
| 1920×1080 | 20 | 0.666 |

当前吞吐包含调试封包和 FT232H 异步 FIFO 输出的背压，不代表 JPEG 编码核独立吞吐。真实摄像头、DDR 缓冲和高速 USB 传输尚待集成；数码管实物显示外观待现场确认。

## 使用

使用 Vivado 2020.1 打开 `mjpeg/mjpeg.xpr`。构建脚本的默认 Vivado 安装目录为 `F:/Xilinx/Vivado/2020.1`，可通过 `-VivadoRoot` 参数指定。

```powershell
./mjpeg/scripts/run_import.ps1 -BoardTest
./mjpeg/scripts/run_progressive_sim.ps1
./mjpeg/scripts/run_mjpeg_board_test.ps1
```

主机侧使用 Python 3；参考生成需要 NumPy 和 Pillow，USB 回读需要 FTDI D2XX 驱动。详细命令见各目录的 README 和测试文档。当前上板验证在 Windows 完成，Ubuntu 接收路径尚未实际验证。

仓库保留源代码、Vivado 工程、测试数据、报告摘要及样图。Vivado 缓存、bitstream、仿真生成物、USB 原始抓包和临时工作目录保留在本地，由 `.gitignore` 排除；报告中的部分构建路径和哈希对应原测试机器的历史产物。
