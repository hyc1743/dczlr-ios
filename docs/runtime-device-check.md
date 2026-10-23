# 在 iPhone 上验证解释器

这个验证包运行的是自制的 `probes/win32_smoke.c` 测试程序，用来检查 Windows
运行时。它还不是已验证可玩的游戏包，也不需要手动启用 JIT。

1. 使用你已有的侧载方式，为 `PortLab-interpreter-unsigned.ipa` 签名并安装，
   然后打开 **PortLab Interpreter**。文件名中的 unsigned 表示尚未签名。
2. 打开 **Settings → Import root filesystem ZIP…**，选择配套的
   `TinyCore15Wine11.0.zip`，直接导入 ZIP 文件。
3. 返回主页，点击 **Run Win32 compatibility check**。首次启动 Wine 可能需要等待；
   云端 macOS 的耗时不能当作手机性能预测。测试提交的是静音缓冲，因此不会播放提示音。
4. 返回主页，点击 **View compatibility report**。如果 Wine 会话仍未退出，先停止会话。
   完整通过时应包含下面六行：

   ```text
   PORTLAB_WIN32_BEGIN
   PORTLAB_FILE_OK
   PORTLAB_THREAD_OK
   PORTLAB_GDI_PIXELS_OK
   PORTLAB_WAVE_BUFFER_OK
   PORTLAB_WIN32_OK
   ```

部分报告可以说明执行到了哪一步；`PORTLAB_FAIL` 会记录失败的操作。
如果没有报告，说明测试尚未创建报告或无法打开存储目录，可以到 **Logs** 查看启动错误。
也可以从“文件”App 的应用目录取出 `RuntimeChecks/portlab-win32-result.txt`。
再次运行测试会清除旧报告。测试专用的 Wine 前缀名为 `portlab-runtime-check`。

配套 Wine ZIP 大小为 162,748,254 字节，SHA-256 为
`41835c49ce0e582a1d7a610243a8e4a95bc59996fb780c09705dc476bb9b6493`。
这是独立的运行时文件，不是已有的游戏资源分卷。

本测试检查文件读写、线程与事件、离屏 GDI 像素，以及音频缓冲完成状态。
即使全部通过，也仍需要继续验证屏幕画面、D3D9、实际声音、输入、速度和可玩性。
Wine 宿主能否正常退出也需要单独验证。
