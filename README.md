# BrightnessBar — 只保留「屏幕亮度」的菜单栏小工具

从 [AetherSwitch](https://github.com/bcblr1993/AetherSwitch)（MIT）提炼的精简版：整个应用只剩
**一个菜单栏图标 + 一个亮度滑杆**，滑杆同时控制内置屏幕与支持 DDC/CI 的外接显示器（各屏按
自身亮度范围映射到相同百分比）。原项目的 CPU/GPU/内存/磁盘/网络/电池监控、保持常亮、隐藏
桌面、显示隐藏文件、深色模式、菜单栏外观设置、开机自启设置、Sparkle 检查更新等全部移除。

## 使用

- 左键点菜单栏太阳图标 → 弹出滑杆，拖动即同步调节所有屏幕
- 右键（或按住 Control 点击）→ 退出
- 按 Mac 亮度键（F1/F2）调节内置屏时，外接屏自动跟随
- 接上/拔掉显示器自动重新识别

## 构建（需要 Xcode Command Line Tools）

```bash
cd BrightnessBar
chmod +x make-app.sh
./make-app.sh          # 产物：build/BrightnessBar.app
```

也可以只跑 `swift build -c release`，直接运行 `.build/release/BrightnessBar`。

## 实现说明

- 无任何第三方依赖；UI 为 AppKit，非 SwiftUI。
- 内置屏：DisplayServices 私有框架（`DisplayServicesGetBrightness` /
  `DisplayServicesSetBrightness[Smooth]`，运行时 dlopen）。
- 外接屏：IOKit 私有 `IOAVServiceCreateWithService` + `IOAVServiceReadI2C/WriteI2C`
  走 DDC/CI（枚举 `DCPAVServiceProxy` 且 `Location == External`；DCP29XX 面板使用
  0xB7 芯片地址），报文与校验和沿用 AetherSwitch 已验证的实现。
- 亮度变化通知：`DisplayServicesRegisterForBrightnessChangeNotifications`。
- 所有 I2C 通信在同一串行队列上执行；滑杆拖动采用"最新值生效"合并，避免请求堆积。

## 与原版的取舍

- 没有原版"低亮度 Gamma 软件补偿"：外接屏调到 0% 时只是显示器自身的最低亮度，可能
  仍微微发光（想全黑需要 Gamma 表补偿，原版约几百行代码，此处省略）。
- 没有外接屏写入的渐变动画跟随（内置屏用系统平滑接口）。
- 没有设置界面：跟随亮度键的行为固定开启，无"零亮度关屏背光"选项。

## 已知限制

- 外接屏需在显示器 OSD 菜单中开启 DDC/CI；部分转接器、虚拟屏、HDR 模式下硬件调节
  可能无效（面板会显示"不可控"数量）。
- 使用了 Apple 私有框架接口（与 MonitorControl、AetherSwitch 相同的做法），仅适合
  自用，不能上架 App Store。
- 同一百分比不代表各屏实际亮度（nits）相同。

## 致谢

- [AetherSwitch](https://github.com/bcblr1993/AetherSwitch)（MIT）——DDC/CI 报文格式、
  IOAVService 调用细节与 DisplayServices 私有 API 用法源自该项目，本项目为其亮度功能
  的精简重写。
- [MonitorControl](https://github.com/MonitorControl/MonitorControl)——同类开源实现，DDC
  思路参考。

## 许可

MIT，见 [LICENSE](LICENSE)。
