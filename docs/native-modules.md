# 原生模块重建记录

本记录对应当前原生重建路线，不对应此前的 Wine 解释器实验。模块编译成功不是完整
游戏或实机可玩性证明。

## 资源：旧式索引 PP

`native/resource/dc_pp.c` 是新编写的可移植 C 模块，使用调用方提供的只读随机访问接口。
它验证八字节头部、每项32字节文件名、每项四字节长度、累计偏移和完整载荷范围；
按条目读取并解码，不将整包加载到内存。文件名保留原始字节。除精确字节查找外，
现在另提供原版路径截取与 ASCII 大小写折叠查找。高位字节的大小写折叠仍未验证，
该查找 API 明确拒绝高位字节查询；不会假装完整支持任意代码页。

本地数据调查和原生模块核对覆盖72个 PP 文件中的71个，共5,011个条目。
每个已识别条目的名称、偏移、长度、首尾抽样读取与独立观察解析器一致。
一个文件不属于当前识别的索引布局，明确拒绝，未按正常资源处理。
这仍不是对完整原版归档加载器的执行对照。

## 已执行的原版函数对照

Ghidra 12.1.4 已完成对固定 PE32 输入的静态分析，工作数据库和导出位于忽略目录
`research/native-core/`。工具从只读参考目录复制到本工作区后，先前的 SLEIGH 写入阻塞
得到解决。导出不是 REA Evidence；本轮使用了独立 Ghidra headless。

已沿实际资源调用确认原版通用 PP 读取入口 `0x00422b40`，它使用字节解码叶函数
`0x004227d0`。该叶函数67字节，源输入 SHA-256 为
`70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07`。
`tools/oracle_pp_codec.py` 只在隔离的 Unicorn 内存中执行这个函数，检查控制流、
cdecl 返回与输出哨兵；不启动 EXE 进程、不调用 Windows API、不运行游戏流程。

已执行163组输入对照：21组合成边界／全字节／随机输入，以及142组实际归档名称和
载荷前缀。新 C 解码器与原版结果逐字节一致，边界哨兵保持。完整归档加载器、
该次解码对照未覆盖文件名归一化；后续名字扫描的对照结果见下段。iOS 执行仍待验证。

随后已对原版名字扫描叶函数 `0x00423250` 的118字节实现做隔离对照。
5,018组有效输入（全部5,011个识别出的条目名称及7组路径／双字节边界）与原生
扫描器结果一致。原版遇到缺少点号的字符串可能越界，原生 API 对此明确拒绝，
不执行原版不安全输入。此叶函数对照不包含 CRT 大小写比较函数。

上一版核心在云端 run `39890729083` 已通过 ARM64 macOS 原生 C 测试与 iPhoneOS
ARM64 编译。当前 iOS 工程已接入相同 C 模块及 Objective-C 只读文件适配器，
主页可检查导入后的 PP 索引和小段读取，仍未启动完整游戏或接入游戏渲染。

集成版本已在 run `39898101455` 通过模拟器和设备构建。下载的阶段 IPA 为
ARM64/iPhoneOS 映像，原生 `dc_pp_open`、`dc_pp_read` 与 `DCArchive` 符号均在包内；
未打包 Windows EXE/DLL。产物名 `PortLab-native-resources-unsigned.ipa`，
SHA-256 `f917f9c315a7f35408257d3fbc092bb73a7a9111f45921a8eacafd21ed0bd95a`。
该包仍显示诊断 Metal 场景，不是已完成的原生游戏包。

`tests/native/test_archive_adapter.m` 在苹果主机上用合成归档直接测试实际 Objective-C
文件适配器，包括部分读取、输出上限、非法索引、损坏布局与文件截断后的 IO 错误。
这与可移植 C 模块测试和 iOS SDK 编译分别记录，不能替代物理设备执行。

Apple 适配器实测已在 run `39898499168` 通过，日志记录
`PORTLAB_APPLE_ARCHIVE_ADAPTER_OK`；同次8项原生 C 测试及 iPhoneOS ARM64 编译通过。
文件适配采用有界 `pread`，避免 stdio 缓存掩盖已截断的底层文件。
包含此实现的阶段 IPA 在 run `39898501922` 构建，下载后确认 ARM64/iPhoneOS、
原生归档及 `_pread` 符号存在。最新阶段包 SHA-256 为
`53f771c1e54368d46a9a0d5193e1cf344218fc6c4641171e48e9af50ffe6a354`，
115,091字节。该小型资源验证包没有游戏逻辑或 MoltenVK 游戏渲染，不能用于
宣称最终游戏 IPA 已完成。

公开的 `tests/fixtures/pp-codec-original-vectors.json` 只包含合成输入的生成参数与
原版输出摘要，不含 EXE 指令或原游戏资源字节。ARM64 云端测试可用这些记录核对
同一 C 模块。Unicorn、Ghidra 和原 EXE 都不进入 iOS 产品。

## 本地复验命令

```powershell
python -m unittest discover -s tests -p test_native_pp.py -v
python tools/audit_native_pp.py --data Data --output research/native-core/native-pp-audit.json
python tools/oracle_pp_codec.py --exe research/target.exe --data Data --output research/native-core/pp-codec-oracle.json
python tools/oracle_pp_names.py --exe research/target.exe --data Data --output research/native-core/pp-names-oracle.json
python -m unittest discover -s tests -p test_native_images.py -v
python tools/audit_native_images.py --data Data --output research/native-core/native-image-audit.json
```

源码仓库没有测试所需的原 EXE 或 Data。原版输入必须与已分析摘要一致；新版本需重新
建立函数与调用约定证据。合成测试仅需要 C 编译器。

`native-core.yml` 分开执行 ARM64 macOS 行为测试和 iPhoneOS SDK 编译，不能把后者
写成 iPhone 上的执行结果。完整游戏、MoltenVK 游戏帧与可玩性尚未完成。

## 图像：BMP、TGA 与 EMA

`native/resource/dc_image.c` 提供无堆分配的探测与解码接口，调用方分别限制输入和输出
大小。输出为左上角起始、紧密排列、非预乘 RGBA8。当前支持 40 字节 DIB、无压缩
24 位 BMP，以及无调色板、无交织的 24／32 位真彩 TGA（原始或 RLE 数据）。
未支持的位深、压缩与头部类型明确失败。解码前检查完整像素流、RLE 包长度及目标
容量；失败不改写目标缓冲区。不在本模块中做缩放、mipmap、色键或 GPU 上传。

EMA 外层为两个 little-endian 32 位尺寸与五字节 `.bmp\0`／`.tga\0` 扩展名标签，
随后是图像。固定 EXE 的 Ghidra 伪代码 `0x0041f130` 静态显示相同的 4＋4＋5 字节
读取顺序，并在交给 D3DX 前写回 BMP 的 `BM` 签名。99 个实际 EMA BMP 的原始签名
为两个零字节，新模块接受这一已观察布局，不修改输入数据。EMA 内外尺寸不一致时
明确拒绝；不模仿原版的越界长度行为。本轮未执行该原版纹理加载函数或 D3DX。

本地完整像素核对见 `research/native-core/native-image-audit.json`：

- 220 个独立 BMP、50 个独立 TGA、1,139 个 EMA，共 1,409 个图像全部与 Pillow 12.3.0
  解码后的尺寸、RGBA 字节一致；包括 42 个使用 TGA RLE 的 EMA。
- Pillow 对照仅对 99 个零签名 BMP 恢复 `BM`，与原版静态加载路径一致。报告保留
  原始条目摘要和解码结果摘要，不导出图像。
- 核对覆盖 71 个可识别 PP 包的独立图像条目，不包含 XX 模型内嵌纹理。此前未识别
  的 `rpsp_02.pp` 仍未解析，不能宣称覆盖所有游戏图像。
- 新增 7 项原生图像测试覆盖四种 TGA 存储方向、透明度、跨行 RLE 包、BMP 行填充、
  EMA 签名恢复、逐字节截断、非法尺寸、输出限制和缓冲区哨兵；本地全套 26 项测试通过。

`DCArchive.decodeImage` 已接入相同 C 模块，按条目后缀选择格式，分别限制编码数据和
RGBA 分配，返回持有独立像素数据的 `DCDecodedImage`。iOS 资源检查每个包最多解码
一个候选图像，并将图像失败与归档失败分开报告。Apple 适配器新增合成像素、大小
限制和非法输入检查，`native-core.yml` 纳入 ARM64 测试及 iPhoneOS 图像模块编译。
提交 `d2233fe` 已在云端 run `39900492387` 通过 ARM64 macOS 的 15 项原生 C 测试、
iPhoneOS ARM64 核心编译，以及实际 Apple 文件／图像适配器执行。日志包含
`PORTLAB_APPLE_ARCHIVE_ADAPTER_OK` 和 `PORTLAB_APPLE_IMAGE_ADAPTER_OK`。
这证明 Apple 主机上的适配器行为；物理 iPhone 上的执行仍未验证。

同一提交的 run `39900423338` 已通过 Ubuntu 全套测试、模拟器 App 和设备 IPA 构建。
下载产物已检查为 ARM64/iPhoneOS 可执行映像，包含 `dc_image_probe`、`dc_image_decode`、
`dc_pp_open`、`DCDecodedImage` 和 `DCArchive` 符号；云端核心报告中的两份 C 源码摘要
与本地一致，没有打包原始 EXE、DLL、PP 或资源分卷。
本地阶段包 `out/PortLab-native-images-unsigned.ipa` 为 118,969 字节，SHA-256 为
`742eb0874f409081850ac9552f86e1917ba3fd5661a52e2e4633cbfcadf54796`。
包内仍是诊断 Metal 场景，不是可游玩游戏；图像解码和构建通过不证明游戏渲染或逻辑完成。

下一步仍需恢复原生渲染及游戏状态机：明确模型和内嵌纹理布局、着色器与渲染状态，
将解码后的图像上传真实 Vulkan/MoltenVK，再验证游戏入口、输入、音频和存档流程。

## 精灵绘制提交

`native/render/dc_sprite.c` 将固定原程序 `0x00420e60` 的绘制提交重建为可移植命令计划。
覆盖四种已观察混合模式、离开模式 3 时的纹理阶段恢复、相同模式缓存、临时 point
过滤及恢复 linear、软件顶点标志、纹理与顶点缓冲绑定、32 字节步长、FVF `0x1c4`，
以及两个三角形的 strip 提交。平台后端需要按顺序执行或等价转换命令；模块自身不调用 GPU。
句柄使用 `uintptr_t`，保留 ARM64 地址宽度，不保留原版 32 位内存结构。

`tools/oracle_sprite_draw.py` 在固定 EXE 摘要下，仅将该函数的 867 字节指令和经检查的
四项跳转表作为分析输入。Unicorn 内存中的八个合成 stdcall 入口捕获原版设备调用的
参数与顺序，不调用 Windows／D3D，不执行原版游戏入口。执行边界受指令地址检查，
原版仅允许写合成栈和混合模式缓存字节；精灵／纹理结构与缓存哨兵均检查不被覆盖。

965 组对照全部通过，逐条命令和最终缓存都与原生模块一致。输入覆盖五种缓存状态
（四种模式与未知状态）、四种当前混合模式、隐藏值 0／1／2／255、过滤值
0／1／2／255、软件顶点值 0／1／255、空精灵与部分零纹理句柄。
原版只有隐藏值恰为 1 才跳过。原生 API 对未验证的混合模式明确失败，不沿用原版的
未知状态。公开夹具只保存合成输入生成规则和原版输出摘要，不含原 EXE 指令。

```powershell
python tools/oracle_sprite_draw.py --exe research/target.exe --output research/native-core/sprite-draw-oracle.json --vectors tests/fixtures/sprite-draw-original-vectors.json
python -m unittest discover -s tests -p test_native_sprite.py -v
```

新增五项本地测试核对上述 965 组原版输出摘要、模式切换与过滤恢复、64 位句柄、错误
不改写输出、命令数组前后哨兵。iPhoneOS 工程及原生核心构建清单已纳入源码；本轮的
ARM64 云端验证已在提交 `512a13c` 的 run `39921045212` 通过：20 项原生测试执行成功，
包括上述精灵命令矩阵；相同源码也通过 iPhoneOS ARM64 编译。下载的 `dc_sprite.o`
已核对为 ARM64 Mach-O 并包含 `dc_sprite_build_plan`，三份核心 C 源码摘要与云端报告一致。
同提交 run `39920980983` 也已通过便携测试、模拟器 App 和设备 IPA 构建。
这些记录不包含物理设备上的游戏绘制。

另已沿缓存写引用定位并恢复精灵入口 `0x0041fe60`：241 字节原版函数的八条调用与
`dc_sprite_begin_plan` 逐项一致，原版会关闭 fog／深度写入、启用 alpha blending、
设置 stage 0 的四个纹理状态、关闭 mip 过滤，并将混合缓存设为 255。
这不建立初始深度比较、alpha test 或其他纹理阶段状态。其他渲染路径
修改相关状态后必须使混合缓存失效。后端成功执行整个计划后才能提交新缓存，执行失败
时必须使缓存失效。Vulkan 状态实现及 GPU 像素对照仍未完成；
提交顺序的原版对照通过不等于游戏已出帧。

## 精灵顶点生成

`native/render/dc_sprite_vertices.c` 重建 `0x00420a60` 的顶点更新行为，生成左上、左下、
右上、右下排列的四个 32 字节顶点。包括尺寸／缩放、支点、旋转、Z、RHW、UV、ARGB
diffuse 和固定 specular。无旋转时，先把支点调整后的左上角截断到整数，再加上宽高；
不能将此行为替换成四角分别取整。颜色同原版截断 `255*channel` 后取低八位，不做 clamp。

`tools/oracle_sprite_vertices.py` 隔离执行固定输入中的顶点函数、两个构造辅助函数和
浮点转整数函数。原版可执行指令限制在这四个已分析函数的指令边界内。Lock／Unlock、
128 字节复制均为有界合成入口，不调用图形设备。旋转矩阵／向量变换交给固定摘要的
微软 x64 `D3DX9_43.dll` 数学函数，**未执行原 x86 D3DX 实现**，两类证据分别记录：

- 128 组正零／负零角度输入，四个顶点的完整 128 字节与隔离原函数逐字节一致。
- 256 组非零旋转输入，除 XY 坐标外的字段逐字节一致，XY 通过绝对误差 `0.001`
  加相对误差 `1e-6` 的检查；本机最大绝对误差为 `0.00048828125`。
- 原版更新只写合成栈，通过有界复制提取输出；输入结构、输出前后哨兵和最终返回均核对。

自制输入含负尺寸缩放、分数坐标、不同支点、UV 和越过 0..1 的颜色值。公开夹具保留
48 组代表性输入／原版输出数值，不含原版指令或资源。数值范围不等于完整浮点输入空间；
原生 API 明确拒绝非有限值和越过 int32 截断范围的输入，不模仿原版的未定义越界行为。
旋转使用平台 libm，不声称恢复了原版三角函数的位级精度。

```powershell
python tools/oracle_sprite_vertices.py --exe research/target.exe --dll-dir .tools/d3dx-reference/build/native/release/bin/x64 --output research/native-core/sprite-vertices-oracle.json --vectors tests/fixtures/sprite-vertices-original-vectors.json
python -m unittest discover -s tests -p test_native_sprite.py -v
```

本地新增四项顶点测试检查原函数数值夹具、旋转与支点、UV／颜色／顺序、负缩放、
非有限值和错误时不修改输出。提交 `45adcaa` 的 run `39923141206` 已在 ARM64 macOS
执行全部 24 项原生测试通过，并编译 iPhoneOS ARM64 核心。下载的
`dc_sprite_vertices.o` 已核对 ARM64 Mach-O、目标符号和源码摘要。相同提交的
run `39923121996` 已通过便携测试、模拟器和设备 App 构建。仍需将顶点与提交计划
接到真实 Vulkan／MoltenVK，原生游戏流程尚未完成。
