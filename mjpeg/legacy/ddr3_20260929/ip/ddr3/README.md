# 达芬奇 A35T DDR3 MIG

最终控制器为 `davinci_ddr3_mig`，使用 Vivado 2020.1 / MIG 4.2 生成；本目录尚不代表实板内存验证通过。

## 硬件依据

本机官方资料盘：`F:/zju/【新资料-Vivado_2020.2-已完结】达芬奇FPGA开发板资料盘（A盘）`。

- `3_开发板原理图和硬件相关文件/达芬奇开发板原理图&装配图V2.1.pdf` 第 1 页：实体 DDR3 为 **NT5CB128M16IP-DI**，第 6 页给出 FPGA 连接。
- 同目录 `达芬奇开发板IO引脚分配表.xlsx`：48 个 DDR3 引脚。
- `4_Source_Code/1_Verilog/Verilog.zip` 内 `Verilog/38_top_ddr3_rw`：官方 MIG 配置 `mig_a.prj` 与生成约束。
- `7_芯片数据手册/03_DDR/NT5CB128M16FP-DI.PDF`：官方提供的南亚 DDR3 家族数据手册。

DDR3 为 x16、2 Gbit（256 MiB）、1.5 V；MIG 沿用官方工程的兼容时序器件 `MT41J128M16XX-125`。实体型号与 MIG 所选时序器件应区别记录。

`vendor_pinmap.json` 的 48 个引脚已与官方 Excel 和官方最终 MIG XDC 逐项验证。官方例程旁的旧 `ddr3_xdc.ucf` 与当前 IO 表不符，不能使用。原始参考与必要原理图页文字保存在 `work/ddr3_20260928/`，未修改资料盘。

## 最终配置与端口

`davinci_mig_lite.prj`：1 个 bank machine、Strict 顺序、native 接口、ECC/Debug 关闭；保留官方温度监测与校准、IO 功耗设置，未修改 DDR 引脚或时序。

- `sys_clk_i` / `clk_ref_i`：均为 200 MHz，No Buffer，连接已有 BUFG 时钟。
- DDR 时钟：400 MHz；PHY 比例 4:1；`ui_clk`：100 MHz。
- `sys_rst`：**低有效**。`ui_clk_sync_rst`：MIG 输出的 UI 同步复位。
- `init_calib_complete`：校准完成之后才能发出内存事务。
- `device_temp[11:0]`：输出，可忽略，但不能作为输入接常量。
- `app_addr[27:0]`：地址以 16 bit word 为单位；16 字节对齐的 byte 地址右移 1 后连接。BL8 命令地址递增 8。
- `app_cmd[2:0]`：读为 1，写为 0；命令握手为 `app_en && app_rdy`。
- `app_wdf_data[127:0]` / `app_wdf_mask[15:0]`：写数据和逐字节屏蔽，mask=1 表示不写。每个 BL8 是一个 UI 数据 beat，`app_wdf_end=1`；握手为 `app_wdf_wren && app_wdf_rdy`。
- `app_rd_data[127:0]` / `app_rd_data_valid` / `app_rd_data_end`：读数据输出。MIG 没有读输出 backpressure，桥必须及时接收。
- 未使用的 `app_sr_req` / `app_ref_req` / `app_zq_req` 接 0，保持 MIG 自身自动刷新。

## 资源对比

单独 MIG OOC 综合，不包括外部桥、JPEG 或官方示例用户 FIFO：

| 配置 | LUT | FF | BRAM | DSP |
|---|---:|---:|---:|---:|
| 官方 4 bank / Normal | 5071 | 4288 | 0 | 0 |
| 1 bank / Normal | 4635 | 4006 | 0 | 0 |
| 最终 1 bank / Strict | 4325 | 3842 | 0 | 0 |

报告保存在 `work/ddr3_20260928/`。Strict 候选与最终同配置重新综合；最终路径见 `mig_final_utilization.rpt`。Normal 对照目录保留在 `work/ddr3_20260928/normal_ip_backup`。

## 工程接入

通过 `read_ip ip/ddr3/davinci_ddr3_mig/davinci_ddr3_mig.xci` 引入，并 `generate_target all`。最终 XCI、DCP、stub 均保存在对应目录。不要只手动读取生成 RTL，否则可能遗漏 PHY 约束。

MIG 主 XDC 自动使用 `SCOPED_TO_REF=davinci_ddr3_mig`、`PROCESSING_ORDER=EARLY`；`_ooc.xdc` 为 IP 单独综合时建立输入 200 MHz 时钟，标记 `out_of_context`。整板工程不要再次全局读取 `_ooc.xdc`，避免重复建立系统时钟。顶层 DDR 端口保持官方 `ddr3_*` 名字与位宽，无需重复编写 GPIO pin 约束。

非 project 流程在资源报告之前应确认 MIG 不再是黑盒，确认已链接 OOC DCP。整板仍须通过布局布线时序、DRC、CDC 和真实校准/读写测试。
