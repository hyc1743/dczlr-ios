# weixing3 的来源与可借鉴方法

## 找到的 Windows → Switch 工程

2026-10-23 检索并核对了公开仓库
[ruje0504-2/biko3-switch-runtime](https://github.com/ruje0504-2/biko3-switch-runtime)，
固定提交为 `63fddc3830b991e725657689934c3b6e3b5786bb`。
其 README 列出的正式 NRO 大小为 16,408,236 字节，SHA-256 为
`31320a8ce44f8e1826fc90ed5b26cb714c551413b286f8c69adb03f9e8b07178`。
本轮重新计算了 `weixing3/switch/biko3/biko3-runtime.nro`，大小与哈希都一致。

这提供了高度匹配的源码来源线索，补上了此前只有 NRO、找不到工程说明的缺口。
本轮未复现其构建，不把 README 的摘要匹配说成源码到成品已完成可复现验证；
仓库账号也不能等同于已核实的个人身份。NACP 中的 ILLUSION 是自报字段。

固定源码来源和参考项目版本记录在 [reference-sources.json](reference-sources.json)。
下载的文本与核对结果保存在被忽略的 `research/port-provenance/`，没有原版游戏代码
执行，也没有把上游实现复制到本产品。

## Windows → Switch 的实际开发方法

| 可确认的方法 | 固定版本中的依据 | 对当前项目的启发 |
| --- | --- | --- |
| 按模块原生重建，而非通用 CPU 转换 | `reports/porting.md` 明确描述无源码输入、原生重建，未实现 Windows/D3D 兼容层；CMake 构建独立 C 模块 | ARM64 游戏逻辑需要逐项恢复和编译；不能等一个自动 EXE 转 NRO 工具 |
| 将原版函数用作离线行为基准 | `tests/original_matrix_oracle.py` 在固定 EXE 摘要下，用 Unicorn 隔离执行矩阵函数，再比较原生模块结果 | 允许分析机上的 x86 对照测试，设备交付仍可没有 CPU 仿真 |
| 纯 CPU 数据层与平台、GPU 分开 | `docs/architecture.md`、`tests/test_architecture.py` 限制依赖方向，渲染头不暴露 Vulkan 类型 | 资源、数学、模型和通用逻辑可以先独立验证，再接苹果宿主 |
| 用 Vulkan 实现重建的渲染语义 | `runtime/render/vulkan/renderer.c` 与构建目标 `bk_render`；Switch 后端使用固定 Mesa NVK | 当前项目可以采用原生 Vulkan 渲染层，苹果端接 MoltenVK |
| 编译工程内的 shader，而非全自动转换原 EXE | `tools/build_shaders.py` 用 glslangValidator 将六份 GLSL 编译为 Vulkan 1.0 SPIR-V，并可运行 spirv-val | 原版 shader/effect 的语义恢复与转换仍需另外完成，不能从成功出图推断全覆盖 |
| 逐层验证并记录历史范围 | 合成边界检查、原函数对照、GPU 回读、主机测试、交叉构建和单独实机记录 | 不把模块测试、原生编译、首帧或主机速度混称为游戏可玩 |

原生矩阵实现还保留了混合浮点精度的处理说明，说明该工程会核对原版数值细节，
而不是把数学 API 名称相同当作行为等价。本轮只研究通用基础方法，没有复跑其
原函数对照测试或游戏流程。

主要原始说明：

- [初期移植记录](https://github.com/ruje0504-2/biko3-switch-runtime/blob/63fddc3830b991e725657689934c3b6e3b5786bb/reports/porting.md)
- [模块与所有权边界](https://github.com/ruje0504-2/biko3-switch-runtime/blob/63fddc3830b991e725657689934c3b6e3b5786bb/docs/architecture.md)
- [矩阵原函数对照测试](https://github.com/ruje0504-2/biko3-switch-runtime/blob/63fddc3830b991e725657689934c3b6e3b5786bb/tests/original_matrix_oracle.py)
- [shader 构建脚本](https://github.com/ruje0504-2/biko3-switch-runtime/blob/63fddc3830b991e725657689934c3b6e3b5786bb/tools/build_shaders.py)

这些文档含有历史状态。初期记录中的“尚未实现”不能直接用于评价后续版本，
路线清单里的旧 1.0.78 成品摘要也不能代替本轮已核对的 README 1.0.79 摘要。

## Switch → iOS 的另一段方法

本地 `weixing3` 参考版本为 `14ab2b4863f1fe9929f080a98a16c7be581e2f26`。
它已经拥有 ARM64 NRO，离线准备与重写工具处理其布局、函数范围和平台专用行为；
宿主再绑定原生平台接口。`Biko3Hooks.c` 在启动时写函数指针数据表，
不是在设备上修改指令页。`Biko3Libnx.c` 保留原有初始化和构造流程，
`Biko3FS.c` 适配文件 ABI，`Biko3Audio.c` 对接音频输出。

其图形桥 `Biko3Vulkan.c` 将实际 Vulkan 调用交给 MoltenVK，处理窗口扩展、
设备能力及前后台同步；不能把其按 NRO 函数地址生成的 hook 表直接套用到当前 x86 EXE。

两段工作要分开理解：前一段重建了可编译的原生运行时，后一段适配已有 ARM64 程序。
当前项目缺的是自己的原生游戏逻辑，找到参考源码并不等于两款游戏的函数、资源格式
或状态机可直接互换。

## 当前采用的路线

原生资源与基础逻辑重建、原版行为对照 → AArch64 编译 → 原生 Vulkan 图形接口 →
MoltenVK → Metal；苹果宿主提供文件、音频、输入和生命周期。
不再要求自写完整直接 Metal 后端，也不恢复设备上的 x86 解释器路线。

参考源码已经按可移植 C 模块组织，另有 Linux 平台后端。这也说明当前项目不必先
制作 Switch NRO 再搬到 iOS：重建出的可移植模块可以直接面向 iOS ARM64 编译，
只在平台和图形后端连接苹果服务。另一游戏的状态机和资源格式仍须独立核对。

保留原着色器离线处理目标，但初步产物可为 SPIR-V。参考工程的脚本只证明离线生成
SPIR-V，不能据此宣称 SPIR-V 到 MSL/Metal 库的处理也已经全部离线完成；若要严格满足
这一点，需进一步核对所选 MoltenVK 版本的构建与加载路径。

当前参考快照中未识别到覆盖原创代码的顶层 LICENSE，GitHub 许可元数据也为空；
THIRD_PARTY 说明了依赖许可。本轮借鉴方法和接口划分，未引入其实现源码。
