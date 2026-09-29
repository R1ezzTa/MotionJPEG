# GRBG 候选的阶段记录

仅将 FPGA 改为 GRBG 的候选固件 `full_20260928_103215` 能正确解读内部色条，但实景由绿色变成明显紫色，未完成颜色修复。

后续光学 RAW、ISP flip 和裁剪对照定位到相位配合问题；最终采用 profile 5 `3820=42` 和 BGGR。请阅读 [RAW 偏色定位与修正](RAW偏色定位与修正.md)。早期推断及反证完整保存在 `work/color_diag_20260928/GRBG_candidate_history.md`。