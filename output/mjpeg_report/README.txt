FPGA 无 DDR3 实时图像处理与 MJPEG 传输系统：LaTeX 报告工程

一、模板
使用 nenhang/ZJU-report-templates 的 latex/group-report.tex：
https://github.com/nenhang/ZJU-report-templates
采用居中封面、article + ctex、左右 2 cm / 上下 1.5 cm 页边距、Fig. 图题、
Consolas 字体与灰底代码框。正文、实拍图、Vivado 原生波形及 7 段源码沿用已有报告。
原模板、MIT 许可和精确 Git blob 标识保存在 template/。
姓名、学号和组号留空，可修改 main.tex 的 reportname、reportstudentid、reportgroup。

二、编译
已验证 TeX Live 2023 XeLaTeX 和桌面编辑器编译器。中文使用 TeX Live 内置 Fandol，
英文与数学使用 TeX Gyre Termes。通过字体文件名加载，避免只依赖系统字体注册。
代码使用模板指定的 Consolas；没有此字体时，可换成 Latin Modern Mono。

在本目录执行两次：
  xelatex -interaction=nonstopmode -halt-on-error main.tex
  xelatex -interaction=nonstopmode -halt-on-error main.tex

推荐执行自动构建，以同时确保 PDF 的中文搜索和复制：
  python -m pip install pypdf
  python build_report.py
若 xelatex 不在 PATH，设置环境变量 XELATEX 指向其可执行文件。
自动构建在两轮 XeLaTeX 后为缺少 ToUnicode 的 Adobe-GB1 字体嵌入标准映射，
不改变字形、排版或图片；标准映射来自 Adobe，原许可保留在文件头。
仅为已编译 PDF 补入映射可运行 python build_report.py --maps-only。
本工程不需要摄像头、Vivado 或原代码仓库的绝对路径即可编译。

三、文件
main.tex          主文档、封面、摘要、目录与样式
sections/         实现、编码与主机、验证、实板和总结章节
code/             7 段实际源码，保留原行号
images/           实拍 JPEG、Vivado 原生完整截图与裁剪、图表
evidence/         回归、实板、资源、时序、原生波形证据与本次验证记录
template/         原始模板、许可与来源信息
asset_manifest.json  素材路径、源码行号与 SHA-256
Adobe-GB1-UCS2    PDF 中文复制所需的标准 Unicode 映射
build_report.py  自动编译与 PDF 字符映射补全工具（依赖 pypdf）

四、证据解释
1. 原生 PNG 是 Vivado 2020.1 打开真实 XSim WDB 后的窗口截图，正文仅裁剪其波形面板。
2. 摄像头链路仿真为 48x16 YUYV 激励，包含一次故意短行故障；实板为 1920x1080 RAW8 输入。
3. 当前演示截图来自 2026-10-26 真实查看器：四模式、六档二值阈值、四档边缘阈值和 Q60/Q75/Q85/返回Q60。处理和 JPEG 编码在 FPGA 内完成。
4. N0/N32 为分时采集同位置裁剪，未锐化，不据此声称 PSNR/SSIM 改善。
5. 载荷图来自硬件 JSON 统计。基础 JPEG 核的既有移植来源记录保存在 evidence/。
6. 物理按钮手感、实际灯光外观及端到端时延仍未完成独立人工/仪器验证。
7. 本次新增真实板卡参数轮换、窗口截图和稳定窗口统计，未修改 RTL 或生产查看器源码。
8. evidence/live_demo_summary.json 与各分段 JSON 保留采样条件、逐帧大小、时间戳及状态。USB 记录带宽含 MBLK 开销，但不是物理总线占用率。
9. evidence/report_capture_session.py 是采集包装脚本，复现需放回原工程 work/，依赖 mjpeg/host 的查看器与实板连接。报告编译不需要运行它。
evidence/waves/ 保留原始 WDB 与相对路径 WCFG，可在 Vivado 中重新打开。

整理日期：2026-10-26。最终报告 32 页，包含 16 张本次实板演示窗口截图。
