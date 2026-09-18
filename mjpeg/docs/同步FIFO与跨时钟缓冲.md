# 同步 FIFO 与跨时钟缓冲

本文记录 50 MHz 同步版的历史结果与命令。当前工作区已升级编码域到 100 MHz，新构建、仿真目录和主机计时参数见 [100 MHz 编码时钟升级](100MHz编码时钟升级.md)；原有 50 MHz 抓包仍按旧计时参数回放。

将达芬奇 USB_SLAVE 的 FT232H 从异步 FT245 切换为同步 FT245。编码核、质量 85、50 MHz 编码时钟和一周期渐进源保持一致，线路继续使用 MBLK 大块协议。无需 ARM 或额外板卡；主机通过 D2XX 控制、接收、解码。

## 实现

- `board_test_ft245_sync.v` 在 FT232H CLKOUT 的 60 MHz 域工作。DATA、WR#、RD#、OE# 从上一个上升沿发出，实际写入以当前上升沿的 WR# 与 TXE# 为准。TXE# 拉高不会消费被阻塞的字节，也不会组合门控 WR# 破坏建立时间。有数据时支持连续每周期一个字节。两字节预取缓冲通过寄存后的尾部占用控制 RAM 出队，隔离外部 TXE 到 RAM 地址/使能的长组合路径。
- `board_test_async_fifo.v` 使用双时钟 RAM、二进制本地指针、跨域 Gray 指针和双级同步器。同步读取的前端字在反压下保持稳定；写入满时停止上游，读取空时不消费。顶层 TX 缓冲为 8 KiB BRAM，RX 命令缓冲为 256 字节分布式 RAM。
- 每个数据管脚使用独立、带初值/异步复位的 I/O 三态寄存器；复位时释放总线。只设置 IOB，不设置阻止打包的 DONT_TOUCH。复位初始状态和读后返回都经过 TURN：先开启 FPGA 输出，下一周期才可发出 WR#，再下一上升沿才发生物理写入。读取命令前先释放 FPGA 数据总线，等待一个完整 CLKOUT 周期后拉低 OE#，再等一个周期才拉低 RD#。命令保持在接收寄存器中，直到 RX FIFO 接受。
- `board_test_cdc_snapshot.v` 用请求/应答握手传递原子链路快照；数据在应答返回前不改变，繁忙期间保留最新未发送快照。物理事件先寄存一拍再进入计数器，每个快照仍覆盖完整 60,000,000 个物理周期，只晚一周期发出；独立 TB 对比采用同样的明确窗口边界。编码 FPS 与数码管仍按 50 MHz 编码域统计。
- `board_test_usb_clock_guard.v` 检测 CLKOUT 心跳：无时钟时保持复位，运行期间时钟消失超过约 1 ms 则复位测试引擎及两个 FIFO；时钟恢复后各域分别同步释放复位。主机选模式时先复位 FTDI bit-mode 并等待 10 ms，再选择 0x40，以清除旧片段。**每次同步主机程序重新打开设备，测试帧号和窗口号均从零开始。**
- `davinci_mjpeg_board_test_top` 默认 `SYNC_FIFO=1`；原异步控制器通过 `SYNC_FIFO=0` 保留用于仿真回归。异步构建不能直接沿用当前同步 XDC。

板卡供应商参考约束将 CLKOUT 映射至 Y4；Vivado 器件数据库确认该脚为 `IO_L11P_T1_SRCC_34`，可使用专用时钟布线。芯片仍采用原 FT245 EEPROM 配置，主机只改变易失 bit-mode，不写 EEPROM 或 FPGA Flash。

## 外部时序与 CDC 约束

依据 [FT232H 官方数据手册表 4.1 与 §4.13](https://ftdichip.com/wp-content/uploads/2024/09/DS_FT232H.pdf)：CLKOUT 周期约 16.67 ns，RXF#/TXE#/读数据的时钟输出延迟为 0–9 ns，写数据和控制信号的建立时间至少 7.5 ns、保持时间至少 0 ns。XDC 对 USB 外部 I/O 建立和保持都进行约束，增加 0.5 ns 板级相对偏差预算及 0.15 ns 时钟不确定度；不再对整个 USB 总线设置 false path。

Gray 指针跨域设置一源周期的 datapath max delay 和 bus skew；快照数据总线限定 transit delay。只有心跳/请求/应答的第一级同步器和异步复位断言路径设置相应例外，不将两组时钟整体 false path。构建输出 CDC、时钟交互、总线偏斜与实际路由建立/保持报告。

DATA/WR#/RD#/OE# 仍为单周期外部时序。三态 T 只在换向时变化，首个物理写入至少晚两个周期；仅 T→DATA 管脚设置 setup=2、hold=1 的多周期约束。释放总线必须赶在下一周期 OE# 之前，因此构建另外逐条检查八个 T 时钟到管脚的数据路径均不超过 8 ns，并保存 `usb_tristate_timing.rpt`。TB 同时检查启用到首写不少于两周期、释放到 OE# 不少于一周期。该例外不影响持续每周期一字节的 DATA 建立时间约束。

主机按同步 FIFO 初始化流程设置 2 ms latency、64 KiB USB 请求及驱动流控；流程参考 [FTDI 同步 FIFO 应用说明 AN_130](https://ftdichip.com/Support/Documents/AppNotes/AN_130_FT2232H_Used_In_FT245%20Synchronous%20FIFO%20Mode.pdf)，FT232H 的模式与时序以其自身数据手册为准。

## 仿真验证

- 双时钟 FIFO 单元：20,125 字节严格保序、1,257 次地址绕回、7,118 个满缓冲阻塞周期；覆盖无 USB 时钟、满队列异步复位、随机有效/就绪、前端保持、暂停/恢复 USB 时钟及心跳保护。
- 独立 FT232H 行为模型将输出标志和读数据延迟到 CLKOUT 后 9 ns；覆盖连续 85 字节写入、短/长 TXE 阻塞、G/V/H/F/S 命令、OE 提前一个周期、总线换向与外部数据/控制建立时间。
- 两次小图 G 会话共 18 帧，以及 VGA/720p/1080p 命令的缩小尺寸渐进仿真共 6 帧，全部逐字节匹配 CPU 参考并完整解码。缩小尺寸结果只用于逻辑验证，不作为实际全尺寸吞吐。
- FPS、帧计时与 60 MHz 物理链路计数分别与独立 TB 事件/时钟/实际总线写入对比。主机模式初始化与解包测试共 13 项通过。

## 全尺寸实板结果（2026-09-18）

使用达芬奇 A35T 和 Windows D2XX，沿用上一版完整彩色渐变图样、质量 85、单周期像素源。实时参考比对/解码和仅接收各运行三档、每档 30 秒；随后逐帧离线验证仅接收的原始抓包。

| 分辨率 | 上一版异步 fps | 同步实时 fps | 同步仅接收 fps | 提升 | 每轮验证帧数 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 640×480 | 101.404 | 144.407 | 144.407 | 42.4% | 4,333 |
| 1280×720 | 34.177 | 48.420 | 48.420 | 41.7% | 1,453 |
| 1920×1080 | 15.239 | 21.605 | 21.605 | 41.8% | 649 |

两轮共 **12,870 帧**均逐字节匹配参考并完整解码；每档停止后的两次零 FPS 窗口通过。三档 JPEG SHA-256 与上一版相同，1080p 仍为 516,557 字节/帧。两轮均从帧号零开始，同一进程内 V/H/F 帧号连续。另有首次小图回读 27 帧和积压恢复后小图 27 帧通过，共 12,924 帧实板 JPEG 完成参考/解码核验。

实测恢复检查：开启连续 1080p，250 ms 内不读 USB，驱动中已有 **65,536 字节**待接收数据；关闭并重开同步链路，使 CLKOUT 模式复位、时钟保护清空跨域状态。之后 G 会话的帧号恢复为 0..26，27 帧全部通过，无旧封包混入。EEPROM word0 仍为 0x0011，主机未写 EEPROM。

最终构建为 `build_20260918_201342`：路由建立裕量 **+0.064 ns**、保持裕量 **+0.008 ns**，Gray 总线偏斜约束通过，关键 CDC 违例为零，DRC 零错误。保留 66 个已有编码流水线/RAM 异步控制警告；CDC 的 4 个 Gray 多位同步警告和 201 个受使能控制数据通路警告经过结构检查，对应 Gray 指针、双时钟 RAM 及保持至应答的快照数据。八个三态寄存器均放入 OLOGIC TFF，释放数据路径为 3.828–3.857 ns，低于独立 8 ns 上限。资源使用为 LUT 64.00%、寄存器 48.53%、BRAM 57.00%、DSP 46.67%。JTAG 下载检查 DONE=1、EOS=1、CRC ERROR=0。

证据：

- [构建和路由报告](../reports/mjpeg_board_test/build_20260918_201342/BUILD_PASS.txt)、[三态换向时序](../reports/mjpeg_board_test/build_20260918_201342/usb_tristate_timing.rpt)、[CDC 报告](../reports/mjpeg_board_test/build_20260918_201342/cdc_routed.rpt)。
- [实时测试](../reports/mjpeg_board_test/hardware_sync_live_20260918/results.json)、[仅接收测试](../reports/mjpeg_board_test/hardware_sync_receive_20260918/results.json)、[仅接收离线验证](../reports/mjpeg_board_test/hardware_sync_receive_20260918/verified_offline/VERIFY_PASS.txt)。
- [积压数据后重开链路](../reports/mjpeg_board_test/hardware_sync_recovery_20260918/recovery_result.json)。
- [汇总证据及源代码/bitstream/抓包哈希](../reports/mjpeg_board_test/build_20260918_201342/sync_throughput_evidence.json)，构建源文件与 bitstream 的哈希均重新核对通过。

## 当前速度限制

1080p 稳态线路写入为 **11.293 MB/s**。60 MHz 物理周期中，有效写入 18.82%、写准备 3.43%、TXE 等待 2.11%、上游无字节 75.64%；读取/换向在稳态窗口中为零。与此前约 7.965 MB/s、六周期异步写时序占用约 95.6% 的状态相比，当前主要限制已经转向 **50 MHz 编码域到大块封包模块的持续供给**。

1080p 喂入一帧平均 45.896 ms，单周期源理想时间为 41.472 ms，输入等待占喂入周期约 9.64%；编码输出握手等待占整帧周期约 37.11%，该数字不等于 FTDI TXE 等待。现有计数尚不能把这部分等待进一步分配给具体编码级或封包环节，需要在后续版本细分这些握手。

仅接收模式把主机 CPU 使用从约 31.1% 降至 6.9%（按单 CPU 核时间口径），但帧率变化不足 0.0001%，主机解码不是本轮主瓶颈。50 MHz 单像素源的 1080p 理论上限约 24.113 fps，此前无输出反压的独立编码核仿真为 23.568 fps；本次实板 21.605 fps 约为独立核仿真结果的 91.7%。增加 CDC FIFO 深度主要吸收突发阻塞，不能直接提高平均上游供给。

数码管仍显示编码域的一秒成功压缩帧数，1080p 稳态预计为 000021/000022，停止后为 000000。USB 计数与数码管驱动仿真已验证，实物显示外观待现场确认。最终测试已停止，板卡保留该同步固件的临时 JTAG 配置。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File mjpeg/scripts/run_sync_fifo_sim.ps1
python mjpeg/host/board_test_receiver.py --capture mjpeg/reports/mjpeg_board_test/simulation_sync_small/sync_small_capture.bin --blocks --sync-fifo --sessions 2 --fps-expected mjpeg/reports/mjpeg_board_test/simulation_sync_small/fps_expected.csv --link-expected mjpeg/reports/mjpeg_board_test/simulation_sync_small/link_expected.csv --output mjpeg/reports/mjpeg_board_test/simulation_sync_small/verified
python mjpeg/host/progressive_test.py --capture mjpeg/reports/mjpeg_board_test/simulation_sync_progressive/sync_progressive_capture.bin --blocks --sync-fifo --simulation --pixel-cycles 1 --timing-expected mjpeg/reports/mjpeg_board_test/simulation_sync_progressive/timing_expected.json --fps-expected mjpeg/reports/mjpeg_board_test/simulation_sync_progressive/fps_expected.csv --link-expected mjpeg/reports/mjpeg_board_test/simulation_sync_progressive/link_expected.csv --output mjpeg/reports/mjpeg_board_test/simulation_sync_progressive/verified
python -m unittest discover -s mjpeg/tb -p 'test_*.py'
```

## 上板与主机运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File mjpeg/scripts/run_mjpeg_board_test.ps1 -Action Build
powershell -NoProfile -ExecutionPolicy Bypass -File mjpeg/scripts/run_mjpeg_board_test.ps1 -Action Program
python mjpeg/host/progressive_test.py --ftdi --blocks --sync-fifo --pixel-cycles 1 --seconds 30 --output mjpeg/reports/mjpeg_board_test/hardware_sync_live_20260918
python mjpeg/host/progressive_test.py --ftdi --blocks --sync-fifo --pixel-cycles 1 --receive-only --seconds 30 --output mjpeg/reports/mjpeg_board_test/hardware_sync_receive_20260918
python mjpeg/host/progressive_test.py --capture mjpeg/reports/mjpeg_board_test/hardware_sync_receive_20260918/usb_capture.bin --blocks --sync-fifo --pixel-cycles 1 --output mjpeg/reports/mjpeg_board_test/hardware_sync_receive_20260918/verified_offline
python mjpeg/host/sync_recovery_test.py --output mjpeg/reports/mjpeg_board_test/hardware_sync_recovery_20260918
python mjpeg/host/analyze_block_throughput.py --live mjpeg/reports/mjpeg_board_test/hardware_sync_live_20260918 --receive mjpeg/reports/mjpeg_board_test/hardware_sync_receive_20260918 --build mjpeg/reports/mjpeg_board_test/build_20260918_201342 --baseline mjpeg/reports/mjpeg_board_test/hardware_one_cycle_live_20260918/results.json --recovery mjpeg/reports/mjpeg_board_test/hardware_sync_recovery_20260918 --output mjpeg/reports/mjpeg_board_test/build_20260918_201342/sync_throughput_evidence.json
```

使用同步固件时必须带 `--blocks --sync-fifo`。同步重开设备会触发时钟保护复位，不要沿用上一进程的 FIRST_ID；同一进程内三档帧号连续。对同步抓包离线回放也带 `--sync-fifo`，使线路速率按 60 MHz 计算。

Ubuntu 使用相同 Python 命令，必要时加 `--library /usr/local/lib/libftd2xx.so`，先按官方 D2XX 运行库说明设置设备访问。本次物理验证环境为 Windows，Ubuntu 尚未实机测试。

计数五类互斥：实际写入字节、写准备开销、上游有字节时 TXE 阻塞、上游无字节、读取/换向。每窗口类别之和为 60,000,000。同步模式不再有每字节六周期的控制器预算；增加缓存只能吸收突发阻塞，不能提高编码核持续供给速率。
