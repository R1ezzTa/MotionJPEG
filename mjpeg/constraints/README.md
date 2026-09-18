# 约束文件

`reference/DaVinci_FPGA_IO.xdc` 是资料盘中的官方完整引脚表，未加入 Vivado 约束集。

`davinci_board_selftest.xdc` 是已完成物理实现及下载的 LED/按键自测约束，只用于对应自测顶层和独立构建脚本。

后续根据 `rtl/top` 中真实板级端口，建立本工程专用 XDC，包含器件引脚、电平标准、输入时钟和外部接口时序。现有模块综合顶层的内部总线不能直接按参考表分配板卡引脚。
