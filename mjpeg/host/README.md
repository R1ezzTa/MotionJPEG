# MJPEG 主机接收与验证

## PC 实时查看画面

当前固件 `full_20260929_153849` 支持彩色、灰度、二值化和 Sobel 四模式，全部由 FPGA 在 JPEG 编码前处理。窗口新增四个模式按钮、亮度阈值和边缘阈值（各 0～255）、“应用阈值”。亮度阈值用于二值化，复位 128；边缘阈值用于 Sobel，复位 32。Sobel 保留达到阈值的灰阶边缘强度，不把弱边缘提升为纯白；两种阈值含义不同。底部按板卡回报显示实际模式/阈值与等待生效的请求，停止时新设置等下一帧生效。

命令行可用 `--preprocess-mode color|gray|binary|sobel`、`--binary-threshold 128`、`--edge-threshold 32`，省略时保留板卡设置。旧固件或回放不能修改模式；更新主机仍兼容旧抓包，新固件的 kind 8 状态需要新版 `block_records.py`。关闭预览后，`preprocess_sweep.py --seconds 3 --output <新报告目录>` 可严格解码各档并保存原始抓包，测量脚本需要 NumPy。完整参数、协议、实板 4293 帧解码、约 30 fps、零溢出及首轮修正见 [板内图像预处理](../docs/板内图像预处理.md)。

当前流程仍采用逐帧独立 JPEG，保留可关闭的板内稳健降噪 v2。窗口支持强度 0～255、应用及关闭/弱 8/中 16/强 32。0 保留原像素，8/16/32 对应四分之一/一半/完整 3×3 中值，另进行两级亮度引导色度平滑；超过 32 只放宽色度平滑门限。新版相同强度的效果与首版 RGB sigma 不同。命令行可用 `--denoise-strength 32`，省略时保留板卡设置；默认复位为 0。

降噪在 FPGA 的 JPEG 编码前执行，PC 只设置强度并显示原 JPEG。新设置按完整帧生效，旧固件和回放禁用修改；状态读回显示 `稳健降噪 v2 请求强度`，旧降噪固件标记 v1。空间滤波可能削弱纹理和同亮度色彩边界，需要同时比较噪点和细节。实现见 [板内稳健降噪](../docs/板内稳健降噪.md)。关闭预览后，可用 `denoise_sweep.py --require-revision 2 --strengths 0,8,16,32,64,255,0 --seconds 4 --output <新报告目录>` 严格解码、保存抓包并比较各档载荷。

此前降噪专项固件 `full_20260928_164542` 的 3330 帧实板解码通过，约 30.002 fps、零溢出，强度 32 连续一分钟通过；真实 Tk 强度/启停/暂停测试也通过，线程正常退出。该 Q85 场景 N0/N16/N32 的 JPEG 载荷约 13.95/10.57/9.29 MB/s；载荷下降不能证明画质改善。实拍细小彩色颗粒有所减少，粗颗粒仍存在，细节变软，用户现场反馈视觉降噪不明显、带宽有降低，主观降噪效果仍未接受。新安装记录见 [v2 降噪验收](../reports/ddr3/denoise2_acceptance_20260928/summary.json)；首版用户反馈保存在 [旧降噪实验](../docs/板内空间降噪.md)。

此前 DDR3 全位置复用和自适应实验已停止用于当前固件。旧协议解码保留供历史抓包回放，历史实测见 [DDR3 参考缓存](../docs/DDR3参考缓存.md)和[板内自适应阈值](../docs/板内自适应阈值.md)；新固件不发送 SPJ1/SPJ2。旧实验命令行参数仅为历史验收脚本保留，当前 GUI 不再提供对应控件。

当前板卡可直接运行 `camera_viewer.py`，窗口会自动连接 USB_SLAVE，等待 PC 的“开启传输”按钮或板载 KEY0 启动，并根据帧描述符识别 VGA/720p/1080p 尺寸。PC 的“停止传输”或 KEY0／KEY3 停止后，窗口继续接收状态并等待下一次启动。KEY1 切画质，KEY2 补光；映射和 LED 指示见 [板载控制说明](../docs/板载按键摄像头控制.md)。`--auto-start` 可由 PC 发送 C 自动开始。Windows 会自动寻找已安装的 FTDI D2XX DLL，默认设备序列号为当前板卡的 `FTB7MA1D`。所需依赖是 Python 3.10+、Pillow 和 Tkinter；当前电脑的 `E:/anaconda/123/python.exe` 已具备这些依赖。

在项目根目录运行：

```powershell
& 'E:/anaconda/123/python.exe' mjpeg/host/camera_viewer.py
# 如果当前 python 环境已有 Pillow/Tkinter，也可以：
python mjpeg/host/camera_viewer.py
```

窗口支持空格暂停/继续显示、`S` 保存当前原始 JPEG、`L` 请求约 2 秒补光、`Esc` 或关闭按钮退出。可切换适应窗口和 1:1 原始像素查看，1:1 模式使用滚动条移动视野。快照默认保存到 `mjpeg/reports/ov5640/preview_snapshots/`，可通过 `--save-dir` 更改。

顶部“板卡图像传输”提供“开启传输”和“停止传输”按钮，分别通过现有 USB `C`／`S` 命令更新板卡运行请求，与 KEY0 控制同一状态。停止会排完当前帧并关补光，随后不再发送图像；USB 连接和状态包继续保留，再点开启即可恢复。状态标签根据板卡读回更新（约每秒一次），不会把按钮点击直接当成已开启。连接或初始化未完成、重连、错误及抓包回放时禁用按钮。原“暂停画面”只冻结 PC 显示，摄像头和 USB 仍继续工作；快捷键 `S` 仍用于保存 JPEG。

2026-09-28 新增 PC 按钮后，22 项查看器测试通过。实际 Tk 窗口通过 USB 完成两轮开启/停止，共接收 162 帧；停止期间接收帧数保持 92、状态窗口继续递增，再次开启后继续收帧，未重连。暂停显示期间仍收到后续 30 帧，证实显示暂停和板卡停止分别生效。解析错误、编码失败和 FIFO 溢出均为 0，两个线程正常退出；本轮没有重新物理按键。完整记录见 [PC 控制实板报告](../../work/pc_transport_20260928/live_gui_summary.json)。本次使用板上已安装的 `full_20260928_105205`，无需重新构建 FPGA。

底部显示尺寸、帧号、JPEG 大小、板内时间戳测得帧率、实际窗口显示帧率、实际传输 MB/s、重建 JPEG MB/s、接收帧数、预览跳过数、编码失败数以及板内输入/压缩/失败 FPS、累计跳帧/丢帧和溢出状态。JPEG 解码和缩放在后台执行，Tk 线程只更新显示，同尺寸图像复用显示缓冲；等待解码的任务和完成结果各只保留最新一个，避免画面队列积压。预览跳过数与 FPGA 丢帧计数分开。暂停显示期间摄像头和 USB 继续工作，关闭时发送停止命令并等待当前帧排空，最后释放设备。预览展示固件实际压缩画面，可用于查看现有偏色和调焦；严格验收仍使用 `camera_receiver.py`。

2026-09-28 在当前 PC 上回放同一段 T64、120 帧抓包，优化前显示 90 帧，优化后显示 111 帧，均无解析/解码错误；T0 的 4 秒回放收到 119 帧、显示 114 帧。暂停、1:1/适应窗口切换、窗口缩放和线程退出通过实际 Tk 回放检查，主机 81 项回归通过。记录位于 `work/preview_motion_20260928/`。这些是 PC 预览测量，不能作为板卡吞吐或运动画质通过的证明；非零阈值复用旧块产生的运动色块仍由固件策略决定，见[噪声与运动伪影定位](../docs/噪声与运动伪影定位.md)。

同日已通过 RAW 诊断和实拍对照定位全局绿色，修正摄像头 profile 5 的 ISP 翻转设置为 `3820=42` 并保持 BGGR；该修正最初安装在 `full_20260928_105205`，本次降噪链路继续沿用。查看器不增加 RGB 增益或颜色滤镜，比较颜色时关闭降噪。详见[RAW 偏色定位与修正](../docs/RAW偏色定位与修正.md)。

也可回放已保存的原始 USB 抓包，按 100 MHz 板内时间戳恢复播放速度，结束后保留最后画面：

```powershell
python mjpeg/host/camera_viewer.py --capture mjpeg/reports/ov5640/progressive_fhd30_60s_20260926_191740/usb_capture.bin
# 自动关闭的短时检查；headless 会独立解码收到的每一帧。
python mjpeg/host/camera_viewer.py --headless --duration 5 --auto-start
# 自动寻找 DLL 失败时，指定本机 D2XX 路径。
python mjpeg/host/camera_viewer.py --library 'C:/Windows/System32/DriverStore/FileRepository/ftdibus.inf_amd64_6d7e924c4fdd3111/amd64/ftd2xx64.dll'
```

一次只运行一个 USB 接收程序。窗口预览可以持续运行，默认只保存手动快照，接收过程中不累计完整视频或整段抓包。`--duration N` 在 N 秒后停止并自动关闭，适合短时测试；`--serial` 用于选择其他 FT232H 数据设备。抓包回放不连接板卡。

查看器及 `block_records.py` 自动识别普通 JPEG 和实验 SPJ1，后者先校验参考帧及区域边界，再重建完整 JPEG。保存的快照仍是标准 JPEG。窗口的“重建 JPEG MB/s”不等于实验传输负载，SPJ1 的区域复用数和负载字节单独显示；带宽结论应使用实际负载或 USB 字节量。`collect_frames=False` 只计传输内容，不执行重建。实验固件可运行 `python mjpeg/host/board_controls_test.py --expect-spatial --output mjpeg/reports/ov5640/my_spatial_test`，校验连续帧、三档量化、全部 JPEG 解码和自动补光关闭。接收期间采用线程池解码；结构校验批量搜索 JPEG 标记，避免逐字节 Python 扫描阻塞 USB 读取。实现及当前无净收益的测量见 [空间块跳过实验](../docs/空间块跳过实现.md)。

运行中按 RESET 会立即中断当前帧，重置 FPGA 帧号、计时和状态窗口；USB/PC 可能仍留有旧包。查看器会自动重开 USB、清理旧缓冲及未完成帧，恢复等待 KEY0 开启；底部保留恢复次数，日志记录中断原因和丢弃帧数。默认恢复不发送 C，继续由板载按键决定启停；显式 `--auto-start` 则在重连后再次启动。连续 3 次重连仍失败会显示错误，避免无限重试。离线抓包解析和 `camera_receiver.py` 的严格验收继续对数据损坏报错，查看器自动恢复不代表视频连续无丢帧。同步 FTDI 初始化在启动 60 MHz 时钟之前清理缓冲，保留随后发送的新 START 包。

## 真实摄像头接收与验收

真实 OV5640 固件使用 `camera_receiver.py`。第一版配置为 VGA 640×480 YUYV，编码时钟 100 MHz；2026-09-26 实测约 15 fps，两次短时接收合计 189 帧全部解码成功，设备重开恢复通过。它自动选择同步 FIFO，以 `C` 开始、`S` 在帧边界停止。逐帧独立解码检查尺寸、状态、帧号和时间戳，保存前五帧 JPEG；真实图像不与渐变参考逐字节比较。完整接入、实测边界和诊断说明见 [OV5640 真实输入](../docs/OV5640真实输入.md)。

```powershell
python mjpeg/host/camera_receiver.py --ftdi --duration 10 --output mjpeg/reports/ov5640/hardware_live
python mjpeg/host/camera_receiver.py --capture mjpeg/reports/ov5640/hardware_live/usb_capture.bin --output mjpeg/reports/ov5640/verified_offline

# 先采集无灯画面，再请求一次 2 秒补光；FPGA 自动关灯。
python mjpeg/host/camera_receiver.py --ftdi --duration 8 --light-pulse --save-count 120 --output mjpeg/reports/ov5640/light_test
```

`summary.json` 给出 JPEG 大小均值、P95、最大值、相对 YUV422 的压缩比/带宽降低比例、目标 15 fps 码率及时间戳测得帧率（可用 `--target-fps 30` 计算另一目标）。`camera_status.json` 保存每秒 MBLK type 7 摄像头状态：初始化完成/失败、芯片 ID、配置索引、PCLK tick、输入帧/丢帧/FIFO 溢出次数与 DVP 有效字节计数。无图像或超时仍保存这些诊断、原始抓包及失败报告。状态计数是累计值，诊断时应同时检查初始值和增量；`summary.json` 的 `camera_diagnostics` 据此提示 SCCB、无 PCLK、无有效视频字节或 FIFO 溢出等可能环节。该推断不能代替引脚时序测量，也不能仅凭丢帧计数认定溢出。同步 FTDI 设备重开会触发链路复位；不要同时运行两个接收程序。

使用 Python 3.10 或更新版本、Pillow 和 FTDI D2XX。`ftdi_fifo.py` 在 Windows 默认加载 `ftd2xx.dll`，在 Ubuntu 默认加载 `libftd2xx.so`，可用 `--library` 指定绝对路径。Windows 已完成实际回读；Ubuntu 路径尚待实机验证。

真实摄像头渐进验收使用 `camera_receiver.py --require-fps 30 --require-no-drops`，要求板内时间戳测得的帧率在目标 ±2% 内，拒绝稳态丢帧、任意 FIFO 溢出和失败 JPEG。`--target-fps` 只用于码率换算，不设置摄像头。新 type 7 状态包含原始 VSYNC 计数和 RAW8 标志；`summary.json` 分开报告 RAW8/YUV422 摄像头输入带宽及 FPGA 内部 YUV422 数据量。档位、完整构建/下载/捕获脚本和实际结果见 [渐进验收](../docs/OV5640渐进验收.md)。

补光命令 `L` 请求约 2 秒点亮，`l`/`S` 关闭；重复 `L` 会重新计时。状态 bit8–11 分别为请求、`3019` 读回确认、控制错误及 SCCB 事务忙。`--light-pulse` 只适用于支持这些命令的新固件，成功报告要求观察到开启读回及最后关闭状态；这不能代替现场确认 LED 实际发光。

当前 100 MHz 同步固件必须带 `--blocks --sync-fifo`，渐进测试及其抓包回放还须加 `--core-clock-hz 100000000`（默认 50 MHz 仅用于历史抓包），通过 `block_records.py` 解析 1 KB JPEG 数据块、帧描述符、FPS、帧计时和 USB 控制器计数。此前异步大块固件只带 `--blocks`；原 1.0.0/1.1.0 固件使用默认旧协议。

当前编码和封包域 100 MHz，USB 60 MHz；升级结果见 [100 MHz 编码时钟升级](../docs/100MHz编码时钟升级.md)。渐进源为一周期一个像素，测试可加 `--pixel-cycles 1` 强制核对；旧渐进固件可加 `--pixel-cycles 2`。缺省识别每档全部帧一致的一/两周期节奏。同步链路及运行方法见 [同步 FIFO 与跨时钟缓冲](../docs/同步FIFO与跨时钟缓冲.md)，此前异步结果见 [单周期像素输入优化](../docs/单周期像素输入优化.md)。

```powershell
# 各尺寸连续 30 秒，接收时逐帧比较参考并解码。
python mjpeg/host/progressive_test.py --ftdi --blocks --sync-fifo --pixel-cycles 1 --core-clock-hz 100000000 --seconds 30 --output mjpeg/reports/mjpeg_board_test/hardware_core100_live_20260918

# 仅接收保存，结束后再完整检查。同步模式每次重开设备会复位测试计数。
python mjpeg/host/progressive_test.py --ftdi --blocks --sync-fifo --pixel-cycles 1 --core-clock-hz 100000000 --receive-only --seconds 30 --output mjpeg/reports/mjpeg_board_test/hardware_core100_receive_20260918
python mjpeg/host/progressive_test.py --capture mjpeg/reports/mjpeg_board_test/hardware_core100_receive_20260918/usb_capture.bin --blocks --sync-fifo --pixel-cycles 1 --core-clock-hz 100000000 --output mjpeg/reports/mjpeg_board_test/hardware_core100_receive_20260918/verified_offline

# 原有三种小图案测试仍可用。
python mjpeg/host/board_test_receiver.py --ftdi --blocks --sync-fifo --sessions 3 --output mjpeg/reports/mjpeg_board_test/hardware_core100_small
```

每次 FPGA 重新配置或同步主机程序重新打开设备后帧号从零开始，同一进程内保持连续。历史异步固件未重新配置时用 `--first-id` 接续帧号。仅接收模式的 CAPTURE_PASS 不代表 JPEG 验证完成；离线回放逐字节比较参考、解码成功后才生成 VERIFY_PASS。

结果保存在各尺寸目录的 `result.json`、`frames.json`、`timings.json`、`fps.json` 和 `link_windows.json`；原始 `usb_capture.bin` 可重新回放。链路计数及稳态窗口选取方法见 [大块封包与链路瓶颈分析](../docs/大块封包与链路瓶颈分析.md)。
