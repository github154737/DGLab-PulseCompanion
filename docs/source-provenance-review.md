# 来源复核与首次公开提交范围

核对日期：2026-10-15。范围是本次候选源码；逐项阅读、文件比对和许可证清点结合进行。这份记录不是人工律师签署的法律意见，也不是对所有历史创作过程的证明。

## 最终公开范围

| 路径 | 纳入理由与边界 |
|---|---|
| `app/lib`、平台工程、`core` | 当前应用与控制核心；平台模板保留 Flutter 例外许可 |
| `app/test`、集成测试、`protocol`、`examples` | 可复现验证与示例；不附真机录音、聊天正文和私有测试报告 |
| `app/tool`、`scripts`、`packaging`、根启动脚本 | 构建、配置、服务及审计工具；实际部署信息来自仓库外配置 |
| `config/public.json`、`config/*.example.json` | 公开默认配置及占位示例；不包含维护者云服务访问权限 |
| `app/assets`、平台图标 | 几何波形图标、依赖声明、仅有 README 的公开波形 ZIP |
| 根文档、`docs` 白名单、`.github` | MIT、第三方声明、使用说明、只读 CI；私人历史文档排除 |
| 锁文件、工程配置 | 固定依赖和构建输入；不含已编译二进制和本机路径配置 |

不纳入：原仓库 `.git` 与辅助快照、`research`、私人波形包、内测码/哈希配置、API/中继密钥、SSH 和签名私钥、部署地址配置、截图、录音、诊断报告、缓存、APK、DLL/SO。原文件仍保留在本机，不为准备公开源码而删除。

提示词属于本次公开源代码，保持现有字节；公开构建仍需要使用者配置自己的服务。私有内测配置不在公开树中。

## 逐项来源核对

| 内容 | 核对依据 | 本次结论/处理 |
|---|---|---|
| `pulse_library.dart` | 逐项阅读格式验证、预览、导出及两个内置数组；对照 openclaw 的解析器 | 本项目读取形状供预览并保留原字节；未引入参考解析器的频率数据表、时长转换和 HEX 生成器。`Dungeonlab+pulse` 是兼容格式名称，不代表使用其所有第三方波形 |
| `core/src/patterns.rs` | 24 个确定性数学形状定义 | 不来自私人波形合集；保留现有代码 |
| `device_gateway.dart`、`physical_output.dart`、`dglab_pairing.dart` | 阅读连接、RPC、回执校验、配对 URI 与输出适配；对照官方线协议、参考项目 relay_client/device_ops | 共同字段和命令常量属于协议兼容内容；当前采用 Dart 客户端实现，未把参考项目 Python/Bun 中继或官方 TypeScript SDK 作为源码/依赖引入 |
| Android `CoyoteProtocol.kt` | 阅读指令编码与限制实现，对照蓝牙协议来源 | 保留 Kotlin 实现；不分发官方应用、固件、SDK 或官方波形包 |
| openclaw 情感引擎 | 阅读 `emotion.ts` 的关键词规则与相对增量 | 当前未引入该引擎；项目采用模型规划、本地执行与回执流程 |
| Windows runner | 与本机 Flutter SDK 模板逐文件比较 | `utils.cpp/h`、`win32_window.cpp/h` 去除换行差异后完全一致。NOTICE 明确保留 Flutter BSD 归属；其他生成的骨架同样按其来源处理 |
| 头像、图标、语音探针、安装脚本 | 查看代码绘制、SVG/图标生成入口、PCM worklet 与安装脚本 | 未发现随公开资源携带角色照片、商业字体或第三方素材包；原始图标设计及生成脚本保留 |
| 依赖声明 | 检查 284 条清单记录及引用的原文路径 | 100 条 Dart/SDK、11 条 Rust core、173 条隔离协议测试记录；全部存在非空许可证文件。并非所有依赖都会进入 APK |

辅助比对范围：277 个候选代码文件与两个参考项目的 73 个代码文件，按去空白后的连续五个有效代码行比对，未发现匹配片段。另对上表高风险位置逐项阅读。该方法不能排除改写、跨语言翻译或更短片段，因此不把“无匹配”当作原创性证明。

## 参考版本与许可边界

- [AI-for-Coyote](https://github.com/indhg/AI-for-Coyote/tree/5cc48fee8810cd6d5e7d4e927b34c1e8cbac15e1)：本地核对版本 `5cc48fee8810cd6d5e7d4e927b34c1e8cbac15e1`。主体 CC-BY-NC-4.0；relay 另有 GPL-3.0。下载副本及波形资源不进入本仓库，不能套用本项目 MIT。
- [openclaw-plugin-dg-lab](https://github.com/FengYing1314/openclaw-plugin-dg-lab/tree/e3cb2eb4ca1a602605e95e134098d97b79672d08)：核对版本 `e3cb2eb4ca1a602605e95e134098d97b79672d08`，MIT，FengYing。仅作为来源核查参考；未将代码/数据文件随本次候选源码分发。
- [DG-LAB dglab-kit](https://github.com/dungeonlab-open/dglab-kit)：2026-10-15 核对官方 V4 协议与配对说明；仓库 SDK 为 GPL-3.0，本项目没有将该 SDK 纳入依赖。不得把协议兼容描述理解为获得官方商标授权。
- [DG-LAB 蓝牙协议](https://github.com/dungeonlab-open/dglab-bluetooth-protocol)：设备协议事实的参考来源，不随本仓库转载完整文档。
- [Flutter](https://github.com/flutter/flutter/tree/5fc346839b5d0eef006ed8404392afb4dfae428d)：所用 SDK 版本 `5fc346839b5d0eef006ed8404392afb4dfae428d`；BSD 原文见 `third-party/Flutter-LICENSE.txt`。

依赖补充原文取自以下固定版本，原文随 `docs/third-party` 分发：

| 项目 | 上游版本 | 本地声明 |
|---|---|---|
| [Buttplug](https://github.com/buttplugio/buttplug/blob/870a0a2f89d8c45ec0285ca387278c33a34ee84a/LICENSE) | `870a0a2f89d8c45ec0285ca387278c33a34ee84a` | `upstream-buttplug-LICENSE.txt` |
| [jsonschema](https://github.com/Stranger6667/jsonschema/blob/1e244c994dd81a1feb7801556a813c6bf2d45dad/LICENSE) | `1e244c994dd81a1feb7801556a813c6bf2d45dad` | `upstream-jsonschema-LICENSE.txt` |
| [simd](https://github.com/Nugine/simd/blob/d74c030d9dc4f3cae02146d1f497ff62726ef09a/LICENSE) | `d74c030d9dc4f3cae02146d1f497ff62726ef09a` | `upstream-simd-LICENSE.txt` |

## 首次提交验证方法

使用 `export-clean-source.py` 将已审查候选文件复制到仓库外新目录，不复制原 `.git`。按逐文件清单暂存，比较路径、大小和 SHA-256，再运行 `check-source-release.py --staged --history`。提交后检查唯一根提交的所有可达文件对象及小型 ZIP 内容，确认没有意外引用、远端或工作区差异。

本机最终逐文件清单、提交 SHA 与扫描结果另外保存为发布准备证据；它们针对一个具体提交，不把生成后的变化自动视为通过。变更文件、分支或 tag 后须重扫。源码首次提交通过与 APK 发布验收是两件事；本轮不构建或上传安装包。
