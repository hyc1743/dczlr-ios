# iOS 移植实施计划

这份计划针对当前目录中的 Windows PE32 成品，参考 `../weixing3` 的 Switch→iOS 工程组织方式。它描述研究和验证顺序，不声称当前游戏已经能够运行。

当前目标已明确为 **AArch64 原生游戏代码＋苹果平台宿主＋Vulkan/MoltenVK＋原版着色器离线处理**。
执行边界与验收以 [native-runtime-design.md](native-runtime-design.md) 为准。
下文保留已有调查与候选路线记录；解释器方案不再作为交付目标。

## 已知起点

主程序是 32 位 x86 PE，普通导入表包含 D3D9/D3DX9、DirectInput、Win32/GDI、WINMM、COM 和文件接口。`d3d9.dll` 是本地 x86 DLL，含有 DXVK 类型标记和 Vulkan loader 名称。当前游戏仍没有可用原始源码或 ARM64 构建输入；参考游戏 `weixing3` 的 Windows→Switch 公开工程则已找到并核对，见 `weixing3-porting-method.md`。

因此不能把 Switch 客体加载器、libnx 启动路径或 MoltenVK Vulkan hook 直接接到这个 PE 上。当前最有价值的可复用内容是资源导入、日志、存档、输入前端、生命周期处理和“编译/启动/首帧/可玩性”分层报告。

## 阶段 A：建立受控基线

使用 `ios/` 中的 PortLab 工程验证 Metal 首帧、触控坐标、合成音频、原子存档、日志轮转和前后台切换。测试素材全部自制，不依赖游戏目录。

验收证据：

- `log.txt` 记录 Metal 首帧命令完成；用户同时目视确认彩色三角形。
- 拖动、保存、读取和重启后恢复位置。
- 设备实际听到测试音；音频 API 成功不能替代听感确认。
- 后台返回后再次绘制和播放。

## 阶段 B：确认 Windows 图形链

在拥有 Windows 运行环境后，使用一个自制 D3D9 程序和目标程序分别记录：模块加载、D3D9 创建设备、交换链、纹理格式、shader 创建、Present、输入设备和音频初始化。优先用调试器或 API 监视器观察，不修改目标文件。

重点验证：

1. `d3d9.dll` 是否确实由目标加载。
2. DXVK 标记是否来自实际执行路径，还是只存在于未使用代码/调试符号。
3. 目标是否依赖 D3DX9 的 effect、sprite、font 和纹理辅助函数。
4. 是否通过 COM 虚表或动态 `GetProcAddress` 调用普通导入表中未列出的 API。
5. DirectInput 和 WINMM 调用的实际格式与时序。

当前已经选择 Vulkan/MoltenVK 后端。这一步的调用记录用于界定需恢复的 D3D9／D3DX9 或原生渲染语义与状态范围；不能从 DLL 名称推断完整接口覆盖。

### 已确定的资源边界

REA 的 PE 资源解析已经确认主程序有 13 个资源，其中 7 个命名资源为 `IDR_BUMP`、`IDR_CUBE`、`IDR_GLARE`、`IDR_PARA`、`IDR_SPRITE`、`IDR_TOON`、`IDR_WATER`。它们的文件范围和 SHA-256 记录在 `research/rea-pe-resources.json`，但 payload 仍保持 opaque。

进一步的有界探针发现 7 个资源的首个 little-endian `UInt32` 都是 `0xFEFF0901`，并含有 `g_mW`、`g_mV`、`g_mWV`、`g_mVP`、`g_mWVP` 等 effect 参数名；`IDR_SPRITE` 还出现混合/深度状态参数名。这与 D3DX9 compiled effect 容器高度一致。符号提取又确认了真实 technique 名称，例如 `giTechSprite`、`giTechWater`、`giTechToonN`、`giTechGlareDif` 和 `giTechBumpN`，以及纹理参数 `g_txDecal`、`g_txCube`、`g_txToon`、`g_txBump`。记录见 `research/d3dx-effect-probe.json` 和 `research/d3dx-effect-symbols.json`。这仍不是完整 effect 解析，也不证明运行时选用了哪个 technique。

因此首个实际移植切片应是“effect 资源转换切片”：

1. 在 Windows 测试程序中确认 `FindResource/LoadResource/LockResource` 或等价调用如何取得 effect blob。
2. 使用格式兼容的 D3DX effect 解析器导出 technique、pass、常量、纹理槽和 shader bytecode；不把 magic 当作完整格式解析。
3. 将 HLSL/DX9 shader bytecode 转成 Metal Shading Language 或经过 SPIR-V 中间层转换；保留常量布局、采样器和 blend/depth 状态。
4. 为 iOS 宿主定义 `ResourceId -> converted effect` 接口；原始 `0xFEFF0901` blob 必须拒绝进入 Metal pipeline。
5. 先处理 `IDR_SPRITE` 的单 pass 2D 路径，再处理 cube、bump、toon、water 和 glare 的多纹理/特殊状态。

转换产物的最低契约已经写入 `ios/Resources/converted-effects.schema.json`，校验器是 `tools/validate_effect_manifest.py`。当前工程会拒绝缺少源 SHA-256、绑定信息或 Metal 库路径的 manifest；`research/effect-conversion-status.json` 记录本机没有 FXC/DXC/SPIR-V 转换工具这一事实。

## 阶段 C：选择执行路线

以下为早期候选调查。当前仅考虑产生原生 AArch64 游戏代码的路径，运行时 x86 指令兼容层不符合已确认目标：

| 路线 | 适用前提 | 主要未知 |
| --- | --- | --- |
| 源码重编译 | 找到合法源码和资源接口 | 当前没有源码证据 |
| x86 指令兼容层 | 兼容层支持目标 PE、线程、异常、Win32 子集和所需图形 API | iOS 签名、性能、JIT 限制、系统调用边界 |
| 离线二进制重编译/翻译 | 能够静态恢复控制流、导入、异常和数据引用 | 自修改、间接跳转、浮点和 ABI 恢复 |
| 游戏逻辑重写 | 只复刻通用玩法框架，使用自制素材 | 不再是原程序移植，工作量最大 |

应先在普通测试程序上验证选中的路线，再触及目标程序。路线选择必须记录证据、覆盖范围和未解决的调用。

## 阶段 D：平台适配边界

无论选哪条执行路线，iOS 宿主可以沿用以下边界设计：

- `Documents/game/Data` 或等价目录用于用户导入的数据；导入采用临时文件、校验后原子改名。
- `Documents/saves` 保存用户存档；日志保留当前和上一轮启动记录。
- 触控和实体手柄转成统一的按键、方向和摇杆快照。
- 音频适配层接收明确格式的 PCM 缓冲，并报告真实的启动、暂停和错误状态。
- 前后台切换先暂停绘制/音频，再恢复；不要在后台继续运行未知的客体线程。
- 图形层只暴露目标真正需要的能力；不伪造不支持的格式、shader 或同步语义。

这些是 `weixing3` 工程可以参考的结构，不代表当前目标已经使用同样的 API。

## 阶段 E：设备验收矩阵

每项单独记录：未构建、已编译、已启动、已出首帧、已通过功能。至少覆盖：冷启动、窗口尺寸、触控、手柄、音频、资源读取、存档、后台恢复和重复启动。IPA 生成只能证明打包流程，不证明设备可玩。

## 当前阻塞

当前缺少可用的 AArch64 游戏程序或源码构建输入。从现有 x86 成品离线恢复／重建后再编译是否可行，仍需证明。本游戏的 Vulkan/MoltenVK 渲染与完整离线 shader 处理也未完成。参考项目的 Windows → Switch 公开工程已找到，NRO 摘要与本地输入一致；方法核对见 `weixing3-porting-method.md`。此前解释器 IPA 和 Wine 测试的成功记录见 `runtime-decision.md`，不能用于证明本次原生架构已实现。

Ghidra 12.1.4 headless 已尝试对 ASCII 副本做静态导入，但上级 `weixing3` 安装目录拒绝写入 x86 语言缓存 `x86.sla`，因此没有导出函数或调用图。状态见 `research/ghidra-port-status.json`；本次没有执行或修改目标。
