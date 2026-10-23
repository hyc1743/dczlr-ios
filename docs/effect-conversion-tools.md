# Effect 恢复与离线转换

当前目标是 ARM64 原生游戏代码和 Vulkan／MoltenVK 图形接口；Wine 或 CPU 解释器不进入
这条交付路线。下面的微软 D3DX 仅是 Windows 分析机上的离线对照工具，不进入 iOS。

## 已恢复的 effect 记录

`tools/parse_dx9_effect.py` 是新编写的有界读取器。格式核对参考固定 Wine 提交
`840a939ee526137639665ff5f587224d6a36403f` 的 `dlls/d3dx9_36/effect.c` 和
`preshader.c`；没有复制其运行时实现。

读取器恢复参数类型、默认数值、数组、sampler、annotation、technique、pass、状态和
资源／对象绑定。数值、纹理／shader 对象及 sampler 是当前支持的类型；struct 等未支持
类型明确失败。记录偏移、数量、名字长度、递归层数和对象索引均有限制。参数复制只识别
经检查的单标量 MOV，其他 FXLC 运算保持 opaque，不把未知表达式当作已转换状态。

固定原始 EXE 的七个资源当前全部通过结构读取，共 256 个顶层参数、44 个 technique、
45 个 pass、264 条资源绑定。输出保存在本地忽略目录：

```powershell
python tools/parse_dx9_effect.py research/target.exe research/rea-pe-resources.json --output research/effect-parser/all-effects.json
```

输入必须与资源证据中的 EXE SHA-256、资源偏移、长度和 SHA-256 一致。输出是语义恢复的
输入，尚不是运行时可直接加载的 pipeline。

## shader 范围与独立对照

shader 范围取自真实对象／资源记录，再关联到声明和 pass。对 shader 数组保留所有静态
候选，记录选择表达式的范围和摘要；不猜测游戏运行时实际选中哪个元素。此方法替代
早先仅按 profile／END token 搜索并猜选 preferred shader 的流程。

`tools/audit_dx9_effect_shaders.py` 使用 hash 固定的微软 `D3DX9_43.dll` 调用
`D3DXGetShaderSize` 与 `D3DXDisassembleShader`。本地已核对 158 个声明范围，135 个不同
SHA-256，所有长度相等且反汇编成功：

| Profile | 声明范围数 |
| --- | ---: |
| vs_2_0 | 137 |
| ps_2_0 | 13 |
| ps_1_1 | 7 |
| ps_1_4 | 1 |

这些统计含相同 shader 在不同 effect／对象中的重复声明。不能据此宣称只需支持 SM2；
也不能将字节码长度／反汇编通过视为 SPIR-V 转换、GPU 执行或像素一致性通过。

同一离线核对工具现还调用 `D3DXGetShaderConstantTable` 读取顶层声明。158 个记录中
155 个有 CTAB，恢复 1,607 项常量／sampler 声明，全部按名称对应到所属 effect 的参数。
其中 240 项矩阵的 effect 存储为 row-major、shader 声明为 column-major，报告明确
标记上传时需转置。数值维度、数组长度及类型均检查；通用 effect sampler 与 shader
具体 sampler 类型的差异单独记录。寄存器填充不能直接用 effect 连续存储字节替代。

另外三个记录来自 CUBE、PARA、WATER 的 `ps_1_1` 汇编参数，确实没有 CTAB；不能因此
断言未使用常量／sampler，仍需结合汇编和调用设置恢复。上述声明匹配不证明 GPU 常量
上传、动态 shader 选择或采样绑定已经正确。转换报告保留每个去重输入在各 effect 中
的归属和声明，避免去重时丢失绑定上下文。

```powershell
python tools/audit_dx9_effect_shaders.py --exe research/target.exe --evidence research/rea-pe-resources.json --dll-dir .tools/d3dx-reference/build/native/release/bin/x64 --output research/effect-parser/shaders --export-bytecode
```

报告为 `research/effect-parser/shaders/shader-audit.json`，反汇编及可选 `.dx9` 原始字节码
只保存在本地忽略目录。命令不启动原 EXE，不执行 shader，不创建图形设备。读取库来自
官方 NuGet 包 `Microsoft.DXSDK.D3DX` 版本 `9.29.952.8`，下载包 SHA-256 为
`ead0906ae8a26c18a7525da7490127a2110f7c58f18293738283e30e97c6ea4b`。
脚本在加载 DLL 前核对两份 DLL 的固定摘要，不把它们重新分发到源码仓库或 iOS。

## 精灵路径的新证据

`IDR_SPRITE` 有 47 个参数、1 个 `giTechSprite` technique、1 个 `Pass0`，pass 中有
97 条状态。Vertexshader 和 Pixelshader 都是明确的 NULL。其 140 条资源绑定包含
134 个已识别的标量参数复制，以及 6 个参数／sampler 引用。

因此此 pass 的恢复重点是固定管线的纹理阶段、采样、混合及顶点行为；没有一个隐藏的
SM2 精灵 shader 可以直接提取转换。effect 默认状态也不代表每次绘制的最终状态：固定
EXE 的 Ghidra 导出 `0x00420e60` 静态显示逐精灵设置混合及纹理阶段，`0x00420a60`
更新 32 字节顶点。两者还需要原函数行为对照和原生重建；本轮没有执行它们。

## 可公开的编译器对照夹具

`tests/fixtures/effect-synthetic.fx` 是本工程自行编写的 effect，涵盖数值默认值、数组、
annotation、sampler、固定管线 pass、SM2 shader 和动态 shader 数组选择。
`tools/compile_effect_fixture.py` 用同一固定微软库先读取源码反射信息，再调用
`CompileEffect`，生成 `.fxbin` 和 `effect-synthetic-reflection.json`。
测试将二进制读取结果与独立的源码反射逐项对比，并检查 shader 归属、所有截断位置、
损坏引用、递归 sampler 和未知 preshader 指令。这些夹具不含游戏资源。

```powershell
python tools/compile_effect_fixture.py --dll-dir .tools/d3dx-reference/build/native/release/bin/x64 --source tests/fixtures/effect-synthetic.fx --output tests/fixtures/effect-synthetic.fxbin --reflection tests/fixtures/effect-synthetic-reflection.json
python -m unittest discover -s tests -p test_dx9_effect.py -v
```

便携测试使用已记录的自制夹具，不需要 Windows DLL、原始 EXE 或 GPU。原版 effect 的
完整微软运行时反射仍未验证；本机尝试创建 D3D9 设备未成功。源码反射夹具和原版 shader
长度／反汇编对照分别记录，不将它们混称为原版 effect 已执行。

## 下一转换门槛

1. 对恢复出的 SM1／SM2 shader 离线生成 SPIR-V，检查每个 shader 的转换结果与绑定。
2. 核对常量布局、相对寻址、sampler、坐标约定、pass 状态及游戏运行时参数更新。
3. 为固定管线精灵生成等价的原生 shader，并重建逐精灵状态和顶点逻辑。
4. 接入真实 Vulkan／MoltenVK，执行 GPU 回读对照后再接游戏流程。
5. 若严格要求所有 Metal 库均离线生成，进一步核对 MoltenVK 的离线库加载路径。

现有 `MetalEffect.swift` 仍是诊断场景。`converted-effects.schema.json` 和校验器继续约束
已有 Metal 产物契约，但尚未产生满足实际游戏渲染要求的转换清单。

## 离线转换器构建门槛

`offline-shader-tools.yml` 现固定下载 vkd3d 2.1、SPIRV-Tools 和 SPIRV-Headers
`vulkan-sdk-1.4.304.0` 源码，下载后先核对摘要。工作流先在 Linux 编译转换器，
只转换本工程自制的 shader，再交叉编译 Windows x64 转换器／验证器，最后在
真实 Windows runner 上执行并比较相同输入的 SPIR-V 摘要。源码归档和许可证随工具
产物保留。原版 shader 不进入这些云端任务。

此前 run `39904758142` 已通过 Linux 上三个自制 shader 的转换和 `spirv-val` 校验，
随后在 Windows 交叉编译检查 Vulkan 头文件时失败：复制的 Vulkan 头依赖未复制的
`vk_video` 目录。提交 `512a13c` 补齐该目录后，run `39921040563` 的交叉配置又因
全工程要求探测 Windows Vulkan 库而失败。提交 `3556f3e` 使用上游支持的
`SONAME_LIBVULKAN` 参数（只构建离线 shader 工具），run `39924549009` 已成功构建
1.17 工具，在 Windows 执行三个自制 shader 的转换／校验并与 Linux 输出摘要一致。
下载后已核对工具文件摘要，本地也复验同样三项通过。

但本地对 135 份不同原版输入的实际转换仅有 25 份通过，110 份失败：104 份 vs_2_0
涉及未支持的 `lrp`／`nrm`／`rep` 等；另有 5 份 ps_1_1 和 1 份 ps_1_4 失败。
已将全部结果保留在 `research/effect-parser/spirv-vkd3d-1.17/conversion-report.json`，
不能用简单自制 shader 通过推断覆盖本游戏。

官方 vkd3d 2.1 源码已核对含这些旧指令的降级路径，归档 SHA-256 为
`7510146aff2adfb4ae07ab890701a607e5ff7c66e57100cfc9f630ec92eeda6a`。
工作流已切换此版本，并增加五个自行编写、经微软汇编／长度／反汇编核对的回归 shader，
覆盖 `nrm`、`lrp`、`rep`、`texcoord`、`texm3x2*`、`texbem`、ps_1_4 和 `_bx2`。
新增夹具已在 1.17 上复现失败；新版本实际构建及完整原版转换仍待后续验证。
这些汇编源码和生成字节码均为自制，不含原游戏 shader。

`tools/convert_effect_shaders.py` 在运行转换器前核对全部本地输入摘要；输出先写入独立
临时文件，通过入口 stage 检查和 Vulkan 1.0 的 `spirv-val` 后才写入正式 `.spv`。
报告记录输入、输出、工具摘要和 SPIR-V 的入口、变量与绑定／布局 decoration。
只通过合成夹具分帧的输入与通过微软长度／反汇编核对的原版输入分别标记，不能混称。
GPU 像素一致性和 effect 绑定整合仍是后续独立门槛。
