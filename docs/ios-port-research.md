# iOS 移植技术研究

本阶段只检查可执行文件的架构与普通导入表，不运行程序，不读取或提取剧情、图像、模型、音频资源。输出是技术调查材料，不是可运行的移植版。

## 可复现证据

在项目根目录运行：

```powershell
python tools/pe_audit.py '.\电车之狼R.exe' '.\d3d9.dll' --output research/pe-audit.json
```

`research/pe-audit.json` 保存完整普通导入表、节布局、SHA-256 和覆盖限制。由本地 Python 标准库解析得到，不是 REA Evidence，不包含反编译或运行时结论。

主程序 SHA-256：`70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07`。

## 静态观察

- 主程序为 PE32，Machine 为 `0x014c`（x86），文件大小 5,185,536 字节。
- 导入 `d3d9.dll!Direct3DCreate9`，以及 `d3dx9_24.dll` 的纹理、矩阵、字体、精灵、effect 和 shader 辅助函数。
- 导入 `DINPUT8.dll!DirectInput8Create`。
- 导入 Win32 窗口与消息循环、文件、注册表、计时、GDI、COM 等接口。
- `WINMM.dll` 导入包含 MMIO 与计时函数。普通导入表不足以判断实际音频输出后端，不能据此声称已经找到音频适配入口。
- 本地 `d3d9.dll` 同样是 x86。后续有界字符串检查发现大量 DXVK 类型/符号标记，以及 `winevulkan.dll`、`vulkan-1.dll`。这些支持“它可能是 DXVK 系列图形转换库”的推断；尚未验证准确版本、官方文件一致性及运行时加载关系，不能直接当成 iOS 图形后端。
- 主程序的静态字符串中还能看到 `GetProcAddress`、`LoadLibraryA`、`CoCreateInstance` 和大量 D3DX texture/surface/effect 符号。它们支持“存在动态 API 与 COM 组件边界”的观察，但字符串本身不等于调用路径。

补充扫描记录见 `research/pe-runtime-markers.json`。扫描只保留可打印 ASCII 连续片段，未解析字符串引用，也没有运行目标。

导入表只说明静态依赖，不说明每个函数实际执行，也不覆盖 COM 虚表调用、运行时加载及延迟导入。

## 与上级 weixing3 的比较

已阅读 `../weixing3/README.md`、`docs/port-status.md` 和 `ios/project.yml`。

该项目文档描述的方案是：嵌入客体程序、初始化 libnx/newlib、提供文件/输入/PCM 适配，并通过 MoltenVK 转发 Vulkan 调用。XcodeGen 配置目标架构是 arm64。其 port-status 明确区分编译成功与设备上完整可玩，文档本身不是本次实机验证。

可以参考其工程组织、资源与存档目录设计、触控界面、日志和构建报告的做法。是否复用具体代码，应进一步检查接口边界和许可证。

当前 x86/Win32/D3D9 程序缺少上述客体接口条件。替换应用名、拷贝 EXE 或仅接入 MoltenVK 都不足以运行它。MoltenVK 的输入接口是 Vulkan，不能单独完成 D3D9 与 D3DX9 的兼容。

## 通用研究路线

1. 优先寻找合法可用的源代码；有源码时先构建独立的平台适配层，并在普通测试场景中验证。
2. 无源码时，需要另行评估 x86 指令执行、PE 加载、Win32/COM 兼容、D3D9/D3DX9 图形转换、输入、音频和异常处理。此次静态依赖清单不能证明整条路线可行。
3. 使用自制三角形、棋盘纹理和合成音频，依次验证 iOS 渲染、触控、声音、文件写入与后台恢复。
4. 使用 macOS/Xcode 工具链构建，在目标设备上记录启动、首帧和功能验证结果。当前 Windows 环境未执行 Apple 构建与签名。

研究项目应将“生成工程”“编译通过”“设备启动”“首帧出现”“功能通过”分别记录，避免将空壳 IPA 当成已完成移植。

## 参考成品来源调查（2026-10-23）

用户补充：现有 Switch 移植版只有完整游戏文件，没有原项目地址、作者说明或发布说明。

检查边界包括 `../weixing3/switch/biko3` 的顶层文件、参考工程文档、锁定依赖清单，以及 NRO 的头部、NACP 元数据与有界技术字符串。未运行游戏或读取 Data 内的资源内容。

记录见 `../research/reference-provenance.json`（相对本文目录）。

| 观察 | 含义与限制 |
| --- | --- |
| `switch/biko3` 顶层只有 `game` 与 `biko3-runtime.nro`；`game` 顶层只有 `Data` | 本次顶层检查未发现 Windows EXE、源码或构建脚本；不是整台机器的穷尽搜索 |
| NRO SHA-256 为 `31320a8ce44f8e1826fc90ed5b26cb714c551413b286f8c69adb03f9e8b07178` | 与参考工程文档绑定的输入一致 |
| NACP 自报名称 `biko3-runtime`、作者 `ILLUSION`、版本 `1.0.79` | 只代表文件中的自报字段，不能证明实际移植作者或原始源码来源 |
| NRO 中存在 Mesa、Vulkan 和 devkitPro 路径标记 | 支持其含有 Switch 图形/平台组件的观察，不能单凭字符串判定最初移植过程 |
| 指定的可打印字符串扫描未匹配 Box86、Box64、QEMU、Hangover、WoW64、`wine_get_version` | 不能据此排除重命名、移除字符串或其他兼容方案，也不能推断为源码重编译 |
| 锁定依赖是 nxnative、d2r-mobile 与 nxnative-romfs-archive | 这些材料说明现有 iOS 方案的来源，没有建立 Windows→Switch 的源码来源链 |

当前无法在“源码重编译”“二进制转换”“兼容层”三个候选之间作有证据支撑的选择。因此，先前描述的 Windows→Switch→iOS 是用户提供的背景；本地材料独立支持的是 Switch 成品及其 iOS 适配过程。

### 新发现对通用移植研究的影响

本地 x86 `d3d9.dll` 中存在 323 段匹配 DXVK 的可打印字符串，以及两个 Vulkan loader 名称。可以提出待验证的研究假说：现有 Windows 配置可能已经用图形转换库处理 D3D9 调用。

这一线索值得追踪，但它没有解决 x86 指令执行、Win32/COM、D3DX9 辅助库和 iOS 图形能力匹配问题。现有 x86 DLL 不能因含有 Vulkan 标记而直接替换为 arm64 的 MoltenVK。也没有证据表明它与 Switch 参考版共用同一渲染实现。

后续通用实验可用自制 Windows D3D9 测试程序记录实际加载模块和图形调用，再用普通三角形/棋盘纹理验证候选转换链路。当前未完成此运行时实验，也没有证据支持承诺原程序可在 iOS 上启动。

## 本阶段结果与未知项

完成：架构识别、普通导入表记录、参考工程方案比较。

未完成：反编译、源码恢复、图形调用跟踪、音频后端确认、运行时兼容层、iOS 工程、IPA 构建、设备验证。当前没有可安装或可玩的 iOS 版本。

参考规范：Microsoft Learn《PE Format》、Apple《Writing ARM64 code for Apple platforms》、KhronosGroup/MoltenVK 官方项目说明。它们解释格式和平台边界，不是当前程序的运行证据。
