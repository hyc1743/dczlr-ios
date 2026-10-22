# 通用 iOS 平台实验

该工程只使用自制三角形与合成测试音，演示 Metal 渲染、触控坐标、音频、原子位置存档、本机日志和前后台切换。`PortRuntime.swift` 还定义了后续客体适配可使用的路径、输入、PCM、生命周期和 `IDR_*` 资源标识边界；`MetalEffect.swift` 提供一个自制的 `IDR_SPRITE` 管线作为转换结果的测试替身。它没有 PE 加载器、x86 执行器、Win32 或 D3D9 兼容层，不能运行 Windows 游戏。项目不读取上级游戏目录。

应用启动时会检查 Documents 根目录和 `ResourcePacks/` 中的 `DczlrData.part*.dczdata`。若发现分卷，会使用 Bundle 内的 `DczlrData.manifest.json` 校验并流式恢复到 `game/Data`；缺卷或校验失败会写入日志，不会把不完整数据当作已导入。

工程组织参考 `../../weixing3/ios/project.yml`；此处代码独立编写，未复制其游戏适配代码。部署目标设为 iOS 16 是实验工程的构建配置，最低版本兼容性仍需实际构建和设备验证。

## macOS 构建

安装 Xcode 并完成首次启动配置。安装 XcodeGen 后，从项目根目录执行：

```bash
brew install xcodegen
bash ios/build.sh simulator
```

脚本调用 XcodeGen 生成工程，并调用 xcodebuild 编译。它不会自动启动模拟器。打开 `ios/PortLab.xcodeproj`，选择 PortLab scheme 和模拟器，点击 Run。

需要生成未签名设备 IPA 时运行：

```bash
bash ios/build.sh device
```

输出是 `ios/build/PortLab-unsigned.ipa`，需要使用自己的签名才能安装。也可在 Xcode 的 Signing & Capabilities 中选择自己的 Team、修改唯一 Bundle Identifier，再直接运行到设备。

脚本只写入 `ios/Generated`、`ios/PortLab.xcodeproj` 和 `ios/build`，不会上传文件或修改全局配置。

## 人工验收

1. 启动后看到旋转的彩色三角形。日志记录首帧 GPU 命令完成；这条日志不能代替目视确认屏幕显示。
2. 拖动画面，三角形中心应跟随触点。转屏后继续测试。
3. 点击“播放测试音”，确认听见短促的 440 Hz 声音。播放调用成功本身不能证明实际发声。
4. 移动三角形后点“保存位置”，再拖到其他位置，点“读取位置”，确认回到保存点。
5. 结束程序再启动，点击“读取位置”，确认位置仍可恢复。没有保存文件时应显示读取错误。
6. 切换后台再返回，检查绘制恢复，并再次测试音频。
7. 在“文件”App 的 Port Lab 目录检查 `position.json`、`log.txt` 和上一次启动的 `log.prev.txt`。

## 验证状态

当前环境为 Windows，没有 Swift、Xcode 或 Apple SDK。此工程尚未经过 Swift 编译、Metal shader 编译、模拟器或设备验证；未生成 IPA。静态结构检查通过不等于构建成功。

原程序的依赖研究见 `../docs/ios-port-research.md`。此实验只建立通用平台基线，不代表原程序移植已完成。
