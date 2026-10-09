# 当前功能回归

从仓库根目录运行主机测试：

```powershell
python -m unittest discover -s mjpeg/tb -p 'test_*.py'
```

覆盖 MBLK 完整性、独立 JPEG 解码、摄像头状态、启停、断帧恢复、显示队列、D2XX 初始化，以及降噪／预处理配置。

| 仿真入口 | 验证内容 |
| --- | --- |
| `run_board_controls_sim.ps1` | 按键消抖、启停、三档画质、中途停止、重新启动、原子 N/B/M/E 命令及状态 |
| `run_real_camera_sim.ps1 -AdmitAtHref 1` | DVP、跨时钟 FIFO、编码、短行 abort 恢复与 MBLK，JPEG 逐字节对照 |
| `run_sync_fifo_sim.ps1` | 跨时钟 FIFO、MMCM、同步 FT245 外部时序、背压、实际字节及计数 |
| `run_bayer_sim.ps1 -DenoiseEnable 1 -DenoiseStrength 32` | BGGR → YCbCr → 降噪 → YUV422 独立像素参考 |
| `run_denoise_yuv_sim.ps1` | 中值混合与色度平滑、反射边界、强度极值、随机反压、abort |
| `run_preprocess_sim.ps1` | 彩色直通、灰度、二值化、Sobel、阈值极值与整帧配置 |
| `run_camera_capture_sim.ps1` | DVP 字节顺序、整帧接收、拒绝与 FIFO 溢出 |
| `run_camera_clock_sim.ps1` | 摄像头采样 MMCM |
| `run_ov5640_init_sim.ps1` | SCCB 初始化与补光控制 |
| `run_core_throughput_sim.ps1` | 编码核连续输入和输出背压下的独立 JPEG 参考 |
| `run_progressive_sim.ps1` | 模拟渐变源、三种尺寸、编码与封包金样 |

上述脚本位于 `mjpeg/scripts/`，使用 Vivado 2020.1，并在临时源副本中运行。模拟数据用于验证生产编码、USB 和控制链路，综合固定真实摄像头输入。参考模型位于 `mjpeg/scripts/jpeg_model.py`；像素处理参考采用完整图像计算，不复用硬件流水线与行缓存。
