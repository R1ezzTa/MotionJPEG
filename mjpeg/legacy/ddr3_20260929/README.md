# 已退出当前工程的 DDR3 实验

这里保存 2026-09-29 移出的 DDR3 控制器、MIG IP、旧板级顶层和构建脚本。当前入口为 `scripts/run_camera_build.ps1`、顶层 `davinci_mjpeg_camera_top`，不读取此目录，也不产生 DDR3 时钟或帧间参考事务。板上的 DDR3 复位脚固定为低。

归档是历史材料，原脚本包含原目录和共享 RTL 的假设，不能在此目录直接运行。复现历史固件时应恢复匹配的完整源码快照；本次变更前快照保存在项目根目录 `work/no_ddr3_20260929/before_snapshot/`，历史验收报告仍在 `mjpeg/reports/ddr3/`。后续如重新引入 DDR3，需要重新验证时序、CDC 和实际内存事务。
