# Effect 转换工具路线

修正：早期宽松解析器的 comment/instruction 长度都少算一个 DWORD，生成的旧 raw IR 不可信。现已修正 token framing，并撤销凭 comment 数量自动挑选 shader 的做法。`build_dx9_ir.py` 只接受 schema 2，并要求显式指定 effect 和 offset；旧数据必须重新生成。详见 `runtime-decision.md`。这些 shader 工具仍不是 x86 游戏执行后端，当前主线是先验证实际 CPU/Windows 运行时。

当前主机没有 FXC、DXC、SPIR-V 或 SPIRV-Cross。不要直接根据 D3DX effect 的头字段编写完整解析器。

## 首选解析参考

Wine 的 `d3dx9` effect 实现包含从二进制 effect 初始化的路径，可以作为 D3DX9 effect 格式解析的参考实现。需要将其解析部分隔离成离线工具，只输出结构化 metadata 和 DX9 shader blob；不能把 Wine 的 Windows 图形运行时当作 iOS 后端。

## 转换阶段

1. 用解析器读取一个 `IDR_*` payload，确认 technique、pass、常量、纹理和 shader blob 的范围。
2. 对每个 shader blob 识别 shader model，并保存原始 SHA-256、输入偏移和长度。
3. 使用能处理 DX9 shader model 的转换器生成 MSL 或 SPIR-V；输出 `.metallib` 必须在 macOS 上由 Metal 工具链编译。
4. 写入 `ios/Resources/converted-effects.json`，通过 `tools/validate_effect_manifest.py` 校验。
5. iOS 运行时只读取已校验的 manifest 和 `.metallib`，原始 `0xFEFF0901` blob 继续拒绝。

## 当前可执行的最小切片

先只处理 `IDR_SPRITE`：一个 effect、一个 technique、一个 pass、alpha blend、关闭深度写入。`ios/Sources/MetalEffect.swift` 的合成 shader 已提供宿主管线替身。得到真实转换产物后，只替换 `MetalEffectFactory` 的 shader library 来源，不改变输入、存档、音频或生命周期代码。

## Shader 级别切片

对齐 little-endian token 的扫描已经发现多个资源包含 `vs_2_0` / `ps_2_0`，记录在 `research/d3dx-shader-profiles.json`。因此转换器的第一阶段可限定为 DX9 Shader Model 2.0 的 vertex/pixel 指令，先验证 `IDR_WATER` 或 `IDR_GLARE` 的单一像素路径，再扩展到更复杂的 effect。该扫描没有完成指令边界解析；重复 token 可能来自 effect 元数据表。

`tools/extract_shader_candidates.py` 进一步用 DX9 profile token 和 `0x0000FFFF` 结束 token 记录候选范围，输出 `research/d3dx-shader-candidates.json`。候选范围仍需真正的 DX9 bytecode parser 复核，不能直接当作 technique/pass 的最终绑定。

`tools/parse_dx9_shader.py` 现在会处理 DX9 comment token、指令长度字段和结束 token，输出 `research/d3dx-shader-parse.json`。它做有界的宽松结构验证并记录不确定 token，不声称完成 DX9 语义反编译或 Metal 转换。

当多个候选重叠时，输出会标记一个保守的 `preferred` 候选（优先包含完整 comment 表且结构最短）。这只是后续 parser 的输入选择提示，不是 technique 归属证明。

`tools/build_dx9_ir.py` 将 preferred 候选转成 `dczlr-dx9-raw-ir-v1`，保存原始 operand token 和有限 opcode 标签。它是转换器输入，不是可执行 shader；下一步需要补寄存器类型、常量映射和控制流语义。

`tools/decode_dx9_operands.py` 在不丢弃原始 token 的前提下输出寄存器号、类型位候选、修饰位候选和相对寻址位候选。输出的字段名称明确带有 `candidate`，直到完整 DX9 指令语法验证前不能用于生成最终 MSL。

## 证据边界

`research/d3dx-effect-probe.json` 只证明资源头和参数名的静态观察；`research/effect-conversion-status.json` 记录转换器缺失。没有 parser 输出 technique/pass，也没有声称任何原始 shader 已经在 Metal 上运行。
