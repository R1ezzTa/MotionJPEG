# DDR3 全位置参考缓存

当前主工程已移除 DDR3，历史构建和资源数字保留原记录。当前实现及验证入口见 [无 DDR3 图像链路](无DDR3图像链路.md)。

本方案把同坐标块跳过的参考区域移到板载 DDR3，让单路彩色 1920×1080 的 **全部 4050 个区域**都能参与比较。阈值仍在运行时调节，本阶段不增加运动补偿。旧版只缓存 192 个区域的实现、实测和安装记录保留在[可调阈值实验](空间块跳过可调阈值.md)及[精确块跳过基线](空间块跳过实现.md)中；这些历史结果不等于 DDR3 版实测。

2026-09-28 已完成 DDR3 实板接入并下载完整固件：首轮七档阈值、运行中切阈值、三档画质、启停、自动补光及 60 秒连续测试共 **3575 帧**独立解码通过，平均约 **30.002 fps**，相机 FIFO 溢出为 0。随后定位偏绿并更新至 `full_20260928_105205`，新版本再验收 **1170 帧**通过。当前安装和首轮历史结果分别记录于本文末。

## 容量与覆盖范围

板卡实体 DDR3 为 NT5CB128M16IP-DI，x16、2 Gbit，即 **256 MiB**。型号、引脚、MIG 时钟和所用官方资料见[DDR3 IP 硬件依据](../ip/ddr3/README.md)。本方案使用其中一段固定地址空间保存参考区域，没有把整张 RGB 画面放入片内 BRAM。

| 项目 | DDR3 版 |
| --- | --- |
| 输入目标 | 单路彩色 1920×1080，30 fps |
| 空间区域 | 每区 4 个 YUV422 MCU，对应 64×8 像素 |
| 区域总数 | 每行 30 区 × 135 行 = 4050 区 |
| 区域编号 | 从上到下、每行从左到右；始终比较相同坐标 |
| DDR 槽位大小 | 每区固定 8 KiB，保存完整区域 JPEG 熵码及末尾 RST/EOI |
| DDR 槽位地址 | byte address = `region_index << 13` |
| 参考槽位总容量 | 4050 × 8192 = 33,177,600 字节，**31.640625 MiB** |
| 本地输入缓冲 | 两个 8 KiB 区域缓冲，交替接收和处理 |
| 本地参考预取 | 一个 8 KiB BRAM，实际只读取参考区域的有效长度 |
| 元数据 | 4050 项有效长度，14 bit BRAM；长度 0 表示无效 |

这里的 31.64 MiB 是固定槽位保留空间，不是每帧必需读写的数据量。内存事务只传输有效区域长度，最后一个 16 字节 beat 按有效字节屏蔽。区域编号 4049 对应右下角 `(1856,1072,64,8)`，仿真已单独验证这个最后槽位的更新和复用。

## 区域比较与参考提交

新增缓存模块为[参考缓存 RTL](../rtl/video/jpeg_spatial_skip_ddr.v)，内存访问由[突发桥](../rtl/memory/ddr3_burst_bridge.v)和[MIG 封装](../rtl/memory/mjpeg_ddr3_memory.v)完成。JPEG 编码仍覆盖整张画面，DDR3 扩大的是参考覆盖范围，不代表省去当前帧的 DCT 运算。

有可用参考时，先从对应 DDR 槽读取完整区域到本地预取 BRAM。非零阈值下，两个 Huffman 系数解码器并行恢复参考和当前区域，再用一套比较逻辑按系数位置合并两个稀疏流；各流独立反压，隐含零系数也参与比较。该路径不执行 IDCT，也不搜索其他位置。解码异常时禁止 COPY，发送当前区域。阈值 0 且长度不同时可以直接发送 DATA，省去无用的 DDR 读取。

复用条件仍为所有 Y/Cb/Cr 系数都满足：

```text
abs(current_quantized_coefficient - reference_quantized_coefficient)
    * corresponding_DQT_entry <= threshold
```

阈值可变范围为 **0～255**。0 使用精确长度与字节比较；非零阈值使用反量化 DCT 系数差，包括稀疏熵码中隐含的零系数。阈值不是像素亮度单位，也不是单个像素误差上限；较大的值可能抑制噪点闪烁，同时忽略真实细节或缓慢变化。

选择 COPY 时，既不改 DDR 槽，也不改其元数据，PC 继续使用自己已重建的同坐标区域。选择 DATA 时，把当前区域送给 PC，同时打包成 128 bit 数据写入 DDR；只有输出数据发送完成且内存事务返回完成后，才提交区域长度并释放本地缓冲。

因此，比较参考始终来自上次实际发送的内容，而不是上一个原始输入帧。若原参考是 100，后续变化为 101、102、103，死区容许变化 2，则参考保持 100、100，直到累计差异 3 才更新。更新后再以 103 为参考，避免每次只差 1 而长期冻结。

第一次、新 START、阈值改变、量化表或尺寸改变、参考帧号失步及周期刷新会完整发送 DATA。正常周期仍为每 30 帧刷新一次。阈值和参考信息使用已有 SPJ2 负载，外层 MBLK、PC 重建 JPEG 和查看器的协议保持一致。

## abort 与内存事务恢复

缓存和内存桥共用系统全局复位。相机采集 abort 或编码核心恢复使用独立的 `abort` 请求，不能单独复位缓存而留下半个内存事务。

尚未接受的命令可以撤回。已经接受的读事务继续接收剩余数据直到完成；写事务保留已呈现且受到反压的 beat，随后用 `keep=0` 继续供应剩余 beat，正常完成原来的事务边界。恢复期间关闭新输入和输出，排空后清除本地流水线并使全部参考失效，下一帧完整刷新。

内存错误进入锁定状态，禁止继续接收新帧，系统全局复位才能清除。全局复位同时作用于桥与缓存，可以一起丢弃事务。当前帧号、尺寸和模式在帧开始时锁存；量化失效请求也会保留到内存提交结束，避免提交动作把较晚到达的失效请求覆盖掉。

编码器恢复的异步复位由独立寄存器产生，不能对二进制状态直接组合译码：量化表恢复最后一步的 `WRITE_TABLE=11 → NORMAL=00` 转换可能短暂经过 `RESET_CORE=01`，使刚恢复的表再次清空。注册复位保留原有复位周期和量化回放顺序。

非零阈值下，两路稀疏系数并行合并；任一系数的反量化差值超过阈值，当前块便已确定不能 COPY，立即转 DATA。离开比较状态时同步清除两路解析状态，下一块重新建立 DC 预测；COPY 必须等全部系数与解析结束通过后才能决定。

## 仿真证据与边界

[缓存仿真报告目录](../reports/mjpeg_board_test/simulation_threshold_ddr/)包含以下通过记录：

- 12 个阈值样例，与独立 Python 系数比较器输出的 SPJ2 逐字节一致，覆盖精确 0、阈值刷新、累计漂移、孤立 AC 变化和随机反压。
- 8 个恢复后完整参考样例，覆盖读排空、写反压及 `keep=0` 排空、未接受命令撤回、全局复位、内存错误锁定、较晚到达的量化失效和两个解码器同时持有稀疏系数时的 abort。
- 4 个密集样例，每区域含 1024 个非零系数，区域超过旧版 256 字节限制；参考保持和更新与 Python 一致。
- 4 个完整 4050 区域样例，右下角区域 4049 的输入依次变化 100→101→102→103，参考正确保持 100→100→100→103，证明比较的是实际发送参考。
- 9 个提前结束及解析错误样例，覆盖早期/末尾系数差异、当前及参考的畸形熵码、后续块恢复；DATA 的原始字节和参考提交规则与独立模型一致。

[编码器恢复集成报告](../reports/mjpeg_board_test/simulation_ddr_channel_recovery/recovery_reference.json)使用真实 channel、JPEG 核和 DDR 缓存，两次 abort（含受到反压的 DDR 写排空）后逐项核对全部 128 个量化值及倒数，回放后的完整参考帧重构与 Pillow 解码通过。综合网表检查记录了旧组合译码的异步复位风险，没有声称测量到实际毛刺脉冲。

历史实拍的不同帧 100→101、阈值 32、全部 4050 区域的相同输入[早退对照](../../work/ddr3_20260928/early_exit/different_capture_comparison.json)中，缓存处理从 3,037,069 周期降到 1,337,710 周期（100 MHz 下 30.37→13.38 ms，减少 55.95%），两版 SPJ2 逐字节相同且匹配独立系数模型，565 个 COPY、3485 个 DATA。该结果包含随机内存反压模拟，仍不是实板帧率。

早期单解码器的[完整 FHD 数值验证](../reports/mjpeg_board_test/simulation_threshold_ddr_single/ddr_fhd_reference.json)使用确定性渐变图和理想内存事务模型，100 MHz 编码域下首次完整参考帧为 **42.26 fps**，下一帧对全部 4050 区域执行参考及当前熵码比较，为 **35.63 fps**。两帧 JPEG 与独立 DCT、量化、Huffman 编码参考逐字节一致，也通过 Pillow 完整像素解码。最终[并行版完整验证](../reports/mjpeg_board_test/simulation_threshold_ddr/parallel_validation.json)的第二帧为 **41.99 fps**；相同真实摄像头 JPEG 熵数据反复输入的[缓存压力验证](../reports/mjpeg_board_test/simulation_threshold_ddr_camera/captured_verification.json)为 **52.93 fps**，这是缓存路径及理想内存模型结果，不含真实采集和 MIG 延迟。

相同渐变图的第二帧全部复用，SPJ2 负载为 12,776 字节，重建 JPEG 为 530,301 字节。这是受控重复图像的仿真结果。实际摄像头噪声、系数密度、DDR 延迟、USB 输出及更新比例都会影响吞吐和收益，**35.63 fps 不表示已实拍达到 1080p30，也不能作为实景压缩率**。

首版实板单解码器的阈值 0 测试连续 180 帧、30.002 fps，全部 SPJ 重构、4050 组及末槽 4049、Q85 DQT 和 Pillow 像素解码通过；另外三档画质及自动关补光测试 690 帧通过，FIFO 溢出 0。记录位于 `reports/ov5640/ddr3_diag_20260927_232137/` 和 `ddr3_single_controls_20260927_2331/`。但非零阈值串行解析在 `ddr3_live_preheated_20260927_232137/` 的 T32 第二帧出现 abort；真实输入的两遍符号解析下界已达 33.4 ms，因此该版本不能满足非零阈值下的 30 fps。随后改为并行解码并重新构建与验收，保留上述失败记录。

并行初版 `full_20260927_233229` 的原始 USB 测试仍有问题：T32 第二帧溢出后停止出图，T64 的 161 帧全部重构、4050 个区域及末槽、Q85 DQT、Pillow 解码通过，但有效平均仅 26.82 fps。T64 帧间隔中位数仍约 30 fps，因此验收改用平均帧率及最长间隔，扫描带宽也使用平均帧率。详见 `ddr3_parallel_raw_t32/t64_20260927_2343/`。

该测试中，下一帧丢失的 19 个前帧的 `total_ticks` 全部 ≥3,249,514，下一帧正常接收的前帧全部 ≤3,249,460。传感器周期约 3,333,114 ticks，却在首像素之后约 3,249,49x ticks 就到达下一次 VSYNC 接收判定，提前约 0.836 ms。仅比较 TIM1 总时间与 33.33 ms 会遗漏这个截止条件。DDR 专用顶层使用首行 HREF 判定接收，保留首字节和整帧锁定；普通顶层默认仍在 VSYNC falling 判定。

## 构建、下载与测试入口

在项目根目录 `F:/zju/dasanshangkecheng/HDL` 执行。SelfTest 为独立 DDR3 自测固件，不采集摄像头；Full 为相机、JPEG、全位置参考和 USB 的完整方案。先保留自测及完整构建各自的输出目录。

```powershell
# 独立 DDR3 读写自测，完整布局布线及检查。
& mjpeg/scripts/run_ddr3_build.ps1 -Action SelfTest

# 完整摄像头方案，profile 5 对应 1080p30，启用可调阈值。
& mjpeg/scripts/run_ddr3_build.ps1 -Action Full `
  -CameraProfile 5 -ThresholdEnable 1

# 仅做综合及资源检查，不生成可下载 bitstream。
& mjpeg/scripts/run_ddr3_build.ps1 -Action Synth `
  -CameraProfile 5 -ThresholdEnable 1
```

输出在 `mjpeg/reports/ddr3/selftest_时间/` 或 `full_时间/`。完成实现和检查后才应有 `BUILD_PASS.txt`、bitstream 和 `build_hashes.json`；检查项包括 DDR 引脚及电压、无未解析黑盒、建立/保持时序、CDC、bus skew、DRC 和 USB 外部时序。下载继续用原来的 SRAM JTAG 流程，明确指定这次 DDR 构建目录，不能依赖普通 MJPEG 的 `latest_build.txt`。

```powershell
& mjpeg/scripts/run_mjpeg_board_test.ps1 -Action Program `
  -BuildDirectory F:/zju/dasanshangkecheng/HDL/mjpeg/reports/ddr3/selftest_实际时间

# 自测固件下载后，关闭其他 USB 查看器再运行。
& E:/anaconda/123/python.exe mjpeg/host/ddr3_selftest.py `
  --reopens 3 --output mjpeg/reports/ddr3/my_memory_selftest.json

# 自测通过后，下载通过构建检查的 Full 固件。
& mjpeg/scripts/run_mjpeg_board_test.ps1 -Action Program `
  -BuildDirectory F:/zju/dasanshangkecheng/HDL/mjpeg/reports/ddr3/full_实际时间
```

自测覆盖所有参考槽位及高地址探测点，重新打开 USB 会重启该自测；内存自测吞吐与 JPEG 实拍吞吐是不同指标。下载脚本会核对构建所记录的源文件、约束、IP 和 bitstream 的 SHA256，再检查 JTAG DONE/EOS/CRC。

完整方案下载后，KEY0 启停、KEY1 画质、KEY2 限时补光、KEY3 停止及关灯保持原有交互。PC 查看器的阈值输入框和[阈值扫描工具](../host/threshold_sweep.py)可以继续使用；只有新固件状态确认支持该能力后才发送阈值命令。

```powershell
& E:/anaconda/123/python.exe mjpeg/host/camera_viewer.py --skip-threshold 32

# 每档新 START/END；保存完整抓包和统计。
& E:/anaconda/123/python.exe mjpeg/host/threshold_sweep.py `
  --thresholds 0,8,16,32,64,128,255 --seconds 3 `
  --output mjpeg/reports/ov5640/my_ddr3_threshold_sweep

# 一个连续 START/END 中改变阈值，核对在途旧帧和新参考。
& E:/anaconda/123/python.exe mjpeg/host/threshold_live_change_test.py `
  --thresholds 0,32,64,0 --frames-per-threshold 60 `
  --output mjpeg/reports/ov5640/my_ddr3_live_threshold_change

# 缓存仿真与独立数值对照，不下载固件。
& mjpeg/scripts/run_threshold_ddr_sim.ps1

# 两次 abort 后完整量化表及 DDR 事务恢复集成验证。
& mjpeg/scripts/run_ddr_channel_recovery_sim.ps1 `
  -Python E:/anaconda/123/python.exe
```

一次只运行一个 USB 接收程序。比较不同阈值的主观效果时同时观察细节、缓慢运动、拖影及完整刷新带来的变化；精确压缩率需要同一输入的对照，不使用不同时间拍摄的两段场景直接相除。

## 当前安装：修正偏绿（2026-09-28 上午）

当前板卡 SRAM 为 `full_20260928_105205`：profile 5 的 `3820=46→42`，保持 BGGR、1920×1080 和 30 fps。该变更明显减弱 ISP 翻转与光学 RAW 相位不匹配造成的绿色，未更改 DDR 缓存、阈值策略或补光/按键逻辑，证据及残余冷色、噪声边界见[RAW 偏色定位与修正](RAW偏色定位与修正.md)。

新版本 T0→T32→T64→T0 的 480 帧，以及三档画质、两次启停、补光自动关闭的 690 帧，全部独立 JPEG 解码和 4050 区域验证通过，平均约 30.002 fps，最长间隔 33.33118 ms、相机 FIFO 溢出 0。此次没有重新物理按键或目视 LED/灯光，先前用户确认仍作为交互依据。

新构建 LUT 18464、FF 20831、BRAM 32、DSP 45；WNS +0.002 ns、WHS +0.005 ns、TNS/THS 0，裕量较窄。静态时序、DRC、CDC、bus-skew 和 USB 外部时序检查通过；166 项构建哈希及 JTAG DONE/EOS/CRC 通过。bitstream SHA256 为 `890676c106fb66b9ac7a5558ee2f0cc7c853d8b01a0a415f0ee6d7afeb2c554b`，源码快照在 `work/color_diag_20260928/isp42_source_snapshot`。实际停止状态为 T0、Q85、初始化完成、无初始化/补光错误、关灯；未写 SPI Flash。

当前[验收报告](../reports/ddr3/colour_acceptance_20260928/summary.json)及[安装记录](../reports/ddr3/colour_acceptance_20260928/installed_firmware.json)保留新版本的证据。后续重新下载旧构建需要对应源码快照，不能将下方首轮记录理解为当前板卡版本。

## 首轮实板验收与安装历史（2026-09-28 凌晨）

以下为首轮构建 `full_20260928_000109` 的实际结果。综合[历史验收报告](../reports/ddr3/final_acceptance_20260928/summary.json)和[当时安装记录](../reports/ddr3/final_acceptance_20260928/installed_firmware.json)可直接复查；本轮偏绿修正不改写历史测试。

| 检查项目 | 实际验收记录 |
| --- | --- |
| DDR3 独立构建、路由、CDC/DRC/时序 | `reports/ddr3/selftest_20260927_230838`；BUILD_PASS，48 个引脚匹配官方表，定点审查 FIFO CDC 并保留数据时延和 Gray 指针偏斜检查 |
| 实际校准与所有槽位读写、重复打开 USB | `reports/ddr3/hardware_selftest_20260927/summary.json`：连续 3 次通过；每次写入及读回各 33,185,856 字节，错误 0；校准约 56.37 ms，读写合计约 118.69 MB/s；覆盖全部参考槽及 128 MiB、最高地址探测点，并非对物理 256 MiB 每个地址的全覆盖测试 |
| 完整相机固件资源和路由检查 | `full_20260928_000109`：LUT 18460/20800（88.75%），FF 20831，BRAM 32/50，DSP 45/90；WNS +0.064 ns，WHS +0.030 ns，TNS/THS 0；131 条精确审查 FIFO 数据 CDC，11 个 bus-skew 全通过，48 DDR 引脚匹配官方映射，DRC/bitgen 错误和 critical warning 为 0 |
| 实拍 1080p30、连续帧号、全部独立解码、FIFO 溢出 | `ddr3_final_t64_60s_20260928_0013`：1801 帧、30.001975 fps，最长间隔 33.33115 ms；全部 4050 区域及末区 4049，61 个周期完整刷新、全部 Q85 DQT 及 Pillow 解码通过，无溢出。停止请求后排完一帧在途数据 |
| 各阈值复用比例及实际 USB/负载带宽 | `ddr3_final_sweep_20260928_0011`：0/8/16/32/64/128/255 各 120 帧，共 840 帧；每档平均 30.002 fps、全部独立解码和无溢出。原始 USB 抓包及 wire/payload 统计保留 |
| 运行中切阈值、画质、启停与补光 | `ddr3_final_live_20260928_0010`：0→32→64→0 的 244 帧，30.001971 fps、最长间隔 33.33115 ms；`ddr3_final_controls_20260928_0012`：690 帧，Q60/Q75/Q85、两次 START/END 及约 2 秒补光自动关闭读回通过；两会话平均均约 30.002 fps、最长间隔 33.33114 ms。未重新物理按键或目视灯光，先前用户已确认按键/LED 行为 |
| 板上最终固件、bitstream SHA256、阈值、运行和补光状态 | JTAG SRAM 下载 `full_20260928_000109/davinci_mjpeg_board_test.bit`，DONE/EOS/CRC 与输入哈希通过；SHA256 `9fa36540e690f9daeed1edc8b5e55651b48fa182caefee48436953c66fab8a6c`。最后实际状态读回：T0、请求 Q85、停止、关灯。源码快照 `work/ddr3_20260928/full_final_snapshot`，未写 SPI Flash |

七档扫描的本场景结果如下。负载是 SPJ2 数据量按实际平均帧率换算，完整 USB 数据量和速率在每档 JSON 中；这些不同时间的实拍数据不能作为相同输入对普通 MJPEG 的精确节省比例。

| 阈值 | 平均 fps | COPY 比例 | SPJ2 负载 MB/s |
| --- | --- | --- | --- |
| 0 | 30.002 | 0.03% | 16.582 |
| 8 | 30.002 | 1.38% | 16.552 |
| 16 | 30.002 | 3.77% | 16.401 |
| 32 | 30.002 | 19.80% | 14.596 |
| 64 | 30.002 | 89.82% | 2.274 |
| 128 | 30.002 | 96.67% | 0.927 |
| 255 | 30.002 | 96.67% | 0.925 |

同一段 12 帧原始 JPEG 的[独立离线对照](../reports/ov5640/ddr3_same_input_20260927/summary.json)中，普通 JPEG 共 6,677,510 字节，T0 的 SPJ2 因区域元数据增加 3.64%，T32 减少 5.82%，T64 减少 80.66%；非零阈值的重建图像与本帧原始 JPEG 有差异，阈值收益伴随画质变化。该短时样本不代表所有场景或运动画面。

时序裕量较窄，现有相机 PCLK 非专用路由和 RAM 异步控制警告仍保留；复位后执行缓存失效和量化表重载。本次固定实现的静态检查与短时实板测试通过，尚未完成温度/长期耐久、运动场景收益或颜色画质验收。

2026-09-28 用户实测反馈：阈值 0 时运动画面正常，非零阈值出现快速运动色块和发糊。当前死区仅按同位置反量化 DCT 系数判断，允许复用前次传输的旧块，没有运动保护或逐块最长复用帧数限制；每 30 帧的完整刷新不能保证运动过程不出现旧块。上述传输、DDR 和 JPEG 解码验收不等于运动画质验收。PC 显示优化可以减少预览跳帧，不能消除该类复用误差。现阶段运动画质基线使用阈值 0；后续策略需要同时评估运动画质与带宽，不能只以 COPY 比例验收。详见[定位记录](噪声与运动伪影定位.md)。

旧版测量和失败记录保持原路径，不将它们改写为 DDR3 成功证据，也不把构建目录的新旧顺序当成当前板上固件状态。
