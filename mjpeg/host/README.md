# PC 接收与查看

Python 3.10+、Pillow、Tkinter、FTDI D2XX 为实时查看依赖；测量脚本还使用 NumPy。默认 FT232H 序列号为 `FTB7MA1D`，可用 `--serial`更改。Windows 已实测，Ubuntu D2XX 路径尚待实机验证。

## 查看器

```powershell
python mjpeg/host/camera_viewer.py
python mjpeg/host/camera_viewer.py --auto-start --denoise-strength 16 --preprocess-mode gray
python mjpeg/host/camera_viewer.py --capture <usb_capture.bin>
python mjpeg/host/camera_viewer.py --headless --duration 5 --auto-start
```

窗口“开启传输／停止传输”与 KEY0 更新同一个板卡运行请求，状态以板卡读回为准。停止后保持 USB 连接，排完当前帧并关灯；再次开启可继续接收。空格暂停显示，`S`保存原始 JPEG，`L`请求约两秒补光，`Esc`退出。1:1 模式可滚动查看原始像素；快照目录用 `--save-dir`指定。

模式为 `color|gray|binary|sobel`，亮度与边缘阈值各 0～255，可用 `--binary-threshold`和 `--edge-threshold`设置。降噪强度用 `--denoise-strength`设置，0 直通，8/16/32 对应四分之一／一半／完整中值混合，更高值放宽色度平滑门限。设置按完整帧生效，省略参数保留板卡当前设置。

JPEG 解码和缩放在后台执行，预览队列只保留最新帧。预览跳过数与板卡丢帧数分别统计。按 RESET 打断数据时，实时查看器可重开 USB 并清理未完成帧；默认等待板载键启动，`--auto-start`会重新启动。严格接收器对损坏数据报错。关闭查看器会停止板卡并释放设备；一次只运行一个 USB 接收程序。

## 严格验收

```powershell
python mjpeg/host/camera_receiver.py --ftdi --duration 60 --require-fps 30 --require-no-drops --output mjpeg/reports/camera/my_acceptance
python mjpeg/host/camera_receiver.py --capture mjpeg/reports/camera/my_acceptance/usb_capture.bin --output mjpeg/reports/camera/my_offline
python mjpeg/host/board_controls_test.py --output mjpeg/reports/camera/my_controls
python mjpeg/host/denoise_sweep.py --require-revision 2 --strengths 0,8,16,32,64,255,0 --seconds 4 --output mjpeg/reports/camera/my_denoise
python mjpeg/host/preprocess_sweep.py --seconds 3 --output mjpeg/reports/camera/my_preprocess
```

验收检查完整解码、尺寸、帧号、时间戳、FIFO 溢出、编码失败和状态一致性。`--target-fps`只用于码率换算，`--require-fps`指定验收帧率，均不改变传感器寄存器。输出保存 `summary.json`、帧与状态记录、样图及可回放的原始 MBLK 抓包。补光可用 `camera_receiver.py --light-pulse`检查限时开关读回。

当前解包只处理标准 JPEG 和最终 MBLK 协议。抓包回放辅助程序为 `board_test_receiver.py`。
