# 仿真文件

为本工程的单路板级接口及模块仿真预留。现有验证基线在相邻 `xilinx_mjpeg/tb` 中，本次未将历史双路测试自动设为本工程的单路仿真顶层。

当前预处理使用 `scripts/run_preprocess_sim.ps1`，独立整帧参考验证彩色原样直通、灰度、亮度二值化和带阈值的灰阶 Sobel。覆盖反射边界、正负梯度、阈值 0/255、帧内修改配置、随机反压和 abort；4×2、16×8、1920×8 全部逐像素比对。`run_board_controls_sim.ps1 -SpatialDdr 1 -PreprocessEnable 1` 验证 B/E/M 原子命令、非法值隔离、物理键、旧 JPEG 金样和新 kind 8 状态；默认不启用 kind 8 的回归继续保留旧协议。`test_preprocess_control.py` 覆盖新状态、旧抓包、能力门控、启动顺序及重连恢复。见 [板内图像预处理](../docs/板内图像预处理.md)。

当前稳健降噪 v2 使用 `scripts/run_denoise_yuv_sim.ps1`：逐像素比较独立整帧参考，覆盖 0/8/16/32/64/255、反射边界、孤立离群点、移动边缘、随机停顿、帧内修改强度及 abort。`scripts/run_bayer_sim.ps1 -DenoiseEnable 1 -DenoiseStrength 32` 验证 RAW→YCbCr444→降噪→YUV422，报告使用 `_v2` 后缀保留首版记录；1920×1080 常量测试可加 `-Width 1920 -Height 1080 -Frames 1 -Constant`。数值参考为 `denoise_yuv_reference.py`，直接对九个完整邻域样本排序，不复用硬件排序网络或行缓存。模型降噪性质和真实画质的区别见 [板内稳健降噪](../docs/板内稳健降噪.md)。

同坐标块复用实验使用 `scripts/run_spatial_skip_sim.ps1`，在独立临时源副本中运行 `tb_jpeg_restart`、`tb_mjpeg_spatial_board` 和 `tb_mjpeg_spatial_throughput`。参考模型逐字节校验重启 JPEG、SPJ1 重建、局部变化、画质切换、随机反压和启停；完整 1080p 两帧仿真另测吞吐。`python -m unittest discover -s mjpeg/tb -p 'test_*.py'` 包含参考失步、损坏帧不提交参考和 MBLK 传输长度等主机测试。实景系数保真的离线分析使用 `analyze_spatial_capture.py`，结果和适用边界见 [空间块跳过实验](../docs/空间块跳过实现.md)。

完整摄像头接口回归使用 `tb_mjpeg_real_camera.sv`，覆盖 DVP、异步 FIFO、板级引擎、JPEG 编码和 MBLK 传输。默认在 VSYNC falling 决定接收；`-AdmitAtHref 1` 选择首个 HREF 字节决定接收，与 DDR 摄像头顶层一致。从仓库根目录运行：

```powershell
.\mjpeg\scripts\run_real_camera_sim.ps1
.\mjpeg\scripts\run_real_camera_sim.ps1 -AdmitAtHref 1
```

参数仅接受 `0` 或 `1`，默认值为 `0`。脚本用临时源副本和 `xelab --generic_top` 配置 TB，不修改生产 RTL。两种模式分别写入 `reports/mjpeg_board_test/simulation_real_camera/` 和 `simulation_real_camera_href/`，保留独立报告；`simulation_configuration.json` 记录选择的模式，`real_camera_evidence.json` 包含三帧 golden JPEG 字节一致与独立解码结果。首个 HREF 的临界接收、整帧拒绝、STOP 与首字节保持由 `tb_ov5640_dvp_capture.sv` 的 `ADMIT_AT_HREF=1` 测试补充覆盖。
## Bayer 排列验证

`run_bayer_sim.ps1 -Pattern BGGR|GRBG|GBRG|RGGB` 可选择排列，默认 BGGR 保留历史测试语义。当前 profile 5 最终采用 `3820=42` 和 BGGR，修正 ISP 翻转与光学 RAW 的相位配合。四种排列的小图随机停顿/abort 验证和 BGGR/GRBG 的 FHD 已知颜色场验证通过；仅用内部色条判断 GRBG 的候选实景偏紫，最终定位证据见 [RAW 偏色定位与修正](../docs/RAW偏色定位与修正.md)。


2026-09-29 无 DDR3 主工程：预处理保持原像素参考，Sobel 改为五级并行算术流水线；空间降噪回归扩展到 17 帧，覆盖单乘法混合的正负极值与舍入。主机程序未变，板级控制仿真使用 `-SpatialDdr 0 -PreprocessEnable 1`。完整结果见 [无 DDR3 图像链路](../docs/无DDR3图像链路.md)。
