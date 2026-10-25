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
