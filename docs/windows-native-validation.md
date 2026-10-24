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

脚本会按真实顺序加载地图 `0 → 1 → 3 → 4 → 5 → 6 → 7 → 8`，读取地图、
角色、脸部 morph、eyes/neck、相机和光照资源，并驱动每张地图的一次交互、
存档往返和地图切换。原始资源只从 `--data` 指定的本地目录读取；报告只保存
资源哈希、计数和状态，不复制或上传资源内容。

成功报告至少包含：

```json
{"verified": true, "maps": 8, "interactions": 8}
```

这条命令验证的是原生模块和真实本地资源链，不代表 Apple GPU、音频设备或
物理 iPhone 已经执行。IPA 仍由公共仓库的 iOS workflow 负责构建；本地
Windows 验证不依赖 Xcode 或 macOS。
