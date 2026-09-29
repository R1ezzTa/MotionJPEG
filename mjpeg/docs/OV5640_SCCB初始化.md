# OV5640 SCCB 初始化

首轮真实输入配置为 VGA 640×480、YUV422，字节顺序为 `Y0 U0 Y1 V0`。
`ov5640_init` 使用编码器 100 MHz 时钟，SCCB 为 100 kHz；不生成内部低频时钟。

寄存器的模拟前端、镜头校正、AWB、Gamma、颜色矩阵与 ISP 参数来自本地正点原子达芬奇官方例程：
`4_Source_Code/1_Verilog/Verilog.zip` 内的 `Verilog/39_ov5640_lcd/rtl/i2c_ov5640_rgb565_cfg.v`。
将 RGB 模式改为 `4300=30`、`501f=00`，根据 OmniVision OV5640 CSP3 数据手册 v2.01 确认 YUYV 格式。
有效尺寸 `3808..380b=0280/01e0`；HTS=1600、VTS=1000、PLL 系统分频为 2，目标为约 15 fps。
帧率使用传感器内部 SCLK 和 HTS/VTS 计算，不能直接用 DVP 引脚的字节时钟 PCLK 代替。
按 [Linux 主线 OV5640 驱动](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/ov5640.c) 的 `ov5640_get_sysclk` 公式，本版 `3034=1a` 给出 `bit_div2x=5`（真实分频为 2.5），`3035=21` 给出 `sysdiv=2`，`3036=3c` 给出乘数 60，`3037=13` 给出预分频 3 和 PLL root 分频 2，`3108=01` 给出 SCLK root 分频 2。
因此 `VCO=24 MHz×60/3=480 MHz`，`SCLK=480 MHz/2/2×2/5/2=24 MHz`；按 HTS=1600、VTS=1000，名义帧率为 `SCLK/(HTS×VTS)=15 fps`，帧周期约 66.67 ms。这里的 `×2` 不可遗漏，否则会错误地得到 7.5 fps。
本地 OV 官方 `OV5640_camera_module_software_application_notes_1.3_Sonix.pdf` 第 13.1.1 节 VGA15 配置提供交叉验证：最终 `3035=21`，乘数 `3036=46`（70），其他上述分频一致，HTS=1896、VTS=984；计算 SCLK=28 MHz，`28 MHz/(1896×984)=15.008 fps`，与其 15 fps 标注一致。
引脚 PCLK 还有独立的 DVP 分频：数据手册 v2.01 的 VFIFO 表（第 7-33 页）明确 `460c[1]=1` 时由 `3824[4:0]` 控制。当前 `460c=22`、`3824=02`，预计分频前 PCLK=48 MHz，手动分频后引脚约24 MHz；其准确频率须用板载 PCLK 计数实测。若引脚为24 MHz，VGA YUV422 每行1280个有效字节约53.33 μs。
官方达芬奇指南第1256–1257页以PCLK计算帧率属于针对其具体配置的简化说明，不能据此混同内部SCLK和引脚PCLK。最终帧率须通过VSYNC计数确认，自动曝光也可能延长帧间隔。

`4740=20` 选择上升沿采样 PCLK，当前 ATK 模块上 HREF 高电平对应有效像素，VSYNC 高电平对应帧同步。
首次上板使用 `4740=22` 时，完整帧为 0、FIFO 溢出为 0；每帧采到 982,400 个字节，恰好对应消隐区 `1600×1000 - 1280×480 - 1600×2`，而非 VGA 的 614,400 个图像字节。因此 bit1 必须为 0；不能把资料中的 HSYNC/HREF“active high”术语直接等同于“高电平为像素有效”。首次实测记录保存在 `reports/ov5640/live_20260926_161753/`。
改为 `4740=20` 后，物理芯片 ID 读出 0x5640、关键寄存器读回完成至索引 270，主测试 147 帧 VGA JPEG 全部解码成功，板端时间戳测得约 15 fps。见 [真实输入硬件验收](OV5640真实输入.md)。
VSYNC bit0 的真实极性与数据手册表格相反，这一勘误由 [Linux 主线 OV5640 驱动](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/ov5640.c) 明确记录。
输出数据在 PCLK 下降沿更新，接收逻辑在上升沿采样。

上电序列为 PWDN=1/RESET=0 等待 5 ms，PWDN=0 再等待 5 ms，RESET=1 再等待 20 ms。
读取 `300a/300b`，只接受 `5640`。写入软件复位 `3008=82` 后等待 10 ms，配置时保持软件待机，最后 `3008=02` 启动图像输出，等待 50 ms。
260 次写入后读回格式、尺寸、PLL 位模式、运行状态及 DVP 极性共 9 项，全部匹配才置 `init_done`。
摄像头采集应在 `init_done` 后从新的 VSYNC 帧边界开始。

SDA 为开漏，仅拉低或释放；板卡原理图 R111 为 4.7 kΩ 上拉。
配置模块接口为 `cam_sda_i` 输入和 `cam_sda_drive_low` 输出，SCCB master 对应 `sda_i` 和 `sda_drive_low`。
唯一物理 `IOBUF` 由板级顶层实例化，`I=0`、`T=~cam_sda_drive_low`、`O=cam_sda_i`、`IO=cam_sda`，避免层级 inout 推断出多重输入驱动。
每个地址/数据字节均检查 ACK，失败允许两次重试，累计三次失败后停机。
`init_error_code=1` 表示 ACK 失败，`2` 表示芯片 ID 不符，`3` 表示寄存器读回不符。
`reg_index` 给出当前操作索引，`last_reg_addr` 给出当前地址，`ack_error_count` 为累计 NACK 数；正常最终索引为 270。
硬件 RESET 会重新开始初始化。

初始化中的 `3016=02`、`301c=02` 选择 STROBE GPIO，`3019=00` 保持补光灯关闭；去掉了原例程中 `3019=02` 紧接 `00` 的瞬时启动闪灯。初始化完成后，USB `L`/`l` 通过同一个 SCCB master 写 `3019=02`/`00` 并读回确认，`S` 同时取消补光请求。FPGA 将每次 `L` 的请求限制为约 2 秒，关灯写入及读回还有约毫秒级事务延迟；计时不依赖主机。两次重试仍失败或读回不符时，错误码为 4，设置 `light_error` 并拉低摄像头 RESET。其状态经 USB flags bit8–11 上报，详见 [真实输入说明](OV5640真实输入.md)。

板卡摄像头 P2 第 17 脚为 CMOS_XCLK，连接 FPGA F15。
本地官方《达芬奇之 FPGA 开发指南 V2.3》第 1255 页的图 45.2.2 是 ATK-OV5640 模块原理图，图下正文明确说明模块自带有源晶振，产生 24 MHz 输入时钟；并说明排针 8 位数据接传感器 D[9:2]。
资料路径为 `F:/zju/【新资料-Vivado_2020.2-已完结】达芬奇FPGA开发板资料盘（A盘）/2_文档教程/1_【正点原子】达芬奇之FPGA开发指南 V2.3.pdf`，PDF 第 1255 页与印刷页码相同。
因此对正点原子 ATK-OV5640 模块，可以明确依靠自带 24 MHz 晶振，保持官方例程不主动驱动 F15 的接法。
这项依据只覆盖 ATK-OV5640；若所接模块来自其他厂商且无芯片 ID/PCLK，仍需核实其具体 XVCLK 来源和第 17 脚的电气连接，不能未经确认驱动该引脚。

验证命令：`powershell -NoProfile -ExecutionPolicy Bypass -File mjpeg/scripts/run_ov5640_init_sim.ps1`。
仿真传感器检查完整寄存器写入和 SCCB 读取事务，同时覆盖单次 NACK 恢复、持续 NACK、错误芯片 ID 和错误极性读回。
