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
文件名归一化和 iOS 执行仍分别待验证。

随后已对原版名字扫描叶函数 `0x00423250` 的118字节实现做隔离对照。
5,018组有效输入（全部5,011个识别出的条目名称及7组路径／双字节边界）与原生
扫描器结果一致。原版遇到缺少点号的字符串可能越界，原生 API 对此明确拒绝，
不执行原版不安全输入。此叶函数对照不包含 CRT 大小写比较函数。

上一版核心在云端 run `39890729083` 已通过 ARM64 macOS 原生 C 测试与 iPhoneOS
ARM64 编译。当前 iOS 工程已接入相同 C 模块及 Objective-C 只读文件适配器，
主页可检查导入后的 PP 索引和小段读取，仍未启动完整游戏或接入游戏渲染。

公开的 `tests/fixtures/pp-codec-original-vectors.json` 只包含合成输入的生成参数与
原版输出摘要，不含 EXE 指令或原游戏资源字节。ARM64 云端测试可用这些记录核对
同一 C 模块。Unicorn、Ghidra 和原 EXE 都不进入 iOS 产品。

## 本地复验命令

```powershell
python -m unittest discover -s tests -p test_native_pp.py -v
python tools/audit_native_pp.py --data Data --output research/native-core/native-pp-audit.json
python tools/oracle_pp_codec.py --exe research/target.exe --data Data --output research/native-core/pp-codec-oracle.json
python tools/oracle_pp_names.py --exe research/target.exe --data Data --output research/native-core/pp-names-oracle.json
```

源码仓库没有测试所需的原 EXE 或 Data。原版输入必须与已分析摘要一致；新版本需重新
建立函数与调用约定证据。合成测试仅需要 C 编译器。

`native-core.yml` 分开执行 ARM64 macOS 行为测试和 iPhoneOS SDK 编译，不能把后者
写成 iPhone 上的执行结果。下一阶段是扩展资源服务、接入实际 iOS 宿主并恢复图形／
逻辑模块；完整游戏、MoltenVK 游戏帧与可玩性尚未完成。
