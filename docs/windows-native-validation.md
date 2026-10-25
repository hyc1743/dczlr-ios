# Windows 本地原生验证

`dczlr` 的开发验证不要求 macOS。和 `weixing3` 的模块化移植方式一样，
资源读取、模型/动画、碰撞、交互和地图切换先在宿主机上用原生 C 模块验证；
iOS 只是最后连接图形和系统适配层的平台。Windows 上可以直接使用手头的原始
`Data` 目录运行完整的本地 gameplay 审计。

在项目根目录执行：

```powershell
python tools/audit_playable_loop.py `
  --data "C:\path\to\dczlr\Data" `
  --output "out\windows-playable-loop.json"
```

需要手动逐步体验状态机时，可运行：

```powershell
python tools/native_playable_session.py --data "C:\path\to\dczlr\Data"
```

已有 `save/player.state` 时加 `--load` 可从存档地图开始：

```powershell
python tools/native_playable_session.py --data "C:\path\to\dczlr\Data" --load
```

输入 `i` 完成交互并进入下一张地图，`m dx dz` 移动玩家，`s`/`l` 做原生存档往返，
`q` 退出。该 runner 使用真实 `Data` 和同一套原生状态机，但不渲染画面、不导出资源。

## 原版 Windows 测试前置条件

如果要启动目录中的原版 Windows 程序，先按根目录说明文件的要求为该程序启用
Windows 兼容性模式；该说明文件的原文就是“【需用 [兼容性] 运行 否则游戏卡死】”。
不满足这个条件时，原版可能在启动阶段卡死，不能把这种现象归因于移植代码。

原版目录还附带一个 `注册表.exe`。对它做过静态 PE 检查：它是加壳的 PE32 x86，导入
`advapi32!RegSetValueExA` 和 `RegQueryValueExA`，并通过 `GetProcAddress` 延迟解析其余
API。因此它确实是注册表初始化辅助程序，而不是游戏资源或移植运行时。由于键名和值位于
加壳后的运行时数据中，静态字符串不能可靠还原具体键路径；测试机应先在隔离的 Windows
用户环境中运行该辅助程序，再启动原版。不要把注册表状态或该程序生成的导出文件提交到仓库。

这两个前置条件只适用于运行原版 Windows 参考程序。`audit_playable_loop.py` 使用本地
`Data` 和原生模块，不启动原版 EXE，也不需要 macOS、Xcode 或导入注册表。

原生游戏场景的正常路线在完成当前交互后等待玩家再次激活交互入口，再加载序列中的下一张
地图；最后一张地图进入完成状态。这样连续地图推进由输入驱动，审计脚本的自动推进仍只用于
覆盖资源和状态机边界。

当前游戏场景沿用已核对的 1024×768 菜单坐标。第一行交互入口矩形为
`x=920..1016, y=328..424`；触摸按下后释放才算激活。首次激活需要角色位于交互目标附近，
交互动画完成并等待语音结束后，再次释放第一行即可进入下一张地图。

脚本会按真实顺序加载地图 `0 → 1 → 3 → 4 → 5 → 6 → 7 → 8`，读取地图、
角色、脸部 morph、eyes/neck、相机和光照资源，并驱动每张地图的一次交互、
存档往返和地图切换；同时核对已观察的 map 0 语音链 `ast001_01.wav →
ast002_01.wav`。原始资源只从 `--data` 指定的本地目录读取；报告只保存
资源哈希、计数和状态，不复制或上传资源内容。

成功报告至少包含：

```json
{"verified": true, "maps": 8, "interactions": 8}
```

这条命令验证的是原生模块和真实本地资源链，不代表 Apple GPU、音频设备或
物理 iPhone 已经执行。IPA 仍由公共仓库的 iOS workflow 负责构建；本地
Windows 验证不依赖 Xcode 或 macOS。

Apple 端沿用上级 `weixing3`/`Prototype` 的分工：Ubuntu portable 检查和 Windows
native gameplay 验证先完成，GitHub Actions 的 macOS job 再负责 XcodeGen、MoltenVK、
simulator 编译与启动验证。当前 workflow 默认不构建 device IPA；只有手动 dispatch 时把
`build_ipa` 输入显式设为 `true` 才会执行 IPA job。
