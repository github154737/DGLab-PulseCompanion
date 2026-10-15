# 资源与依赖整理记录

核对日期：2026-10-15。本记录描述已做的技术核查，不等同于律师对所有代码来源的保证。

| 内容 | 本次处理 | 公开范围 |
|---|---|---|
| 自有应用、控制核心、脚本和文档 | 按维护者选择添加 MIT | 含根 LICENSE，第三方例外见 NOTICE.md |
| 私人 user-waveforms.zip | 原文件校验后复制到仓库外；内测构建专用注入 | 不随公开源码/安装包分发 |
| 公开同名 ZIP | 只含 README，保持资源加载与偏好恢复流程 | 无第三方波形 |
| 两个内置波形 | 保留 pulse_library.dart 的已有定义 | 随自有代码发布 |
| Rust 模拟器的 24 个形状 | 检查 patterns.rs，使用三角、正弦、阶梯等数学定义 | 不包含私人合集；不代表校准后的设备剂量 |
| 应用头像、波形图与界面装饰 | Flutter 绘制；未发现需要打包的第三方角色照片 | 随代码发布 |
| 应用启动图标 | 替换 Flutter 模板标识为本项目原创几何波形图标，SVG 与生成脚本保留 | MIT，Android/Windows 使用同一设计 |
| 字体/通用图标 | Flutter Material 与 Cupertino 依赖；未打包 Windows 中文字体 | 保留依赖许可；本机截图字体不分发 |
| Dart/Flutter、Rust | 重新收集 284 条记录及对应原文：100 个 Dart/SDK、11 个 core、173 个隔离协议测试 | docs/third-party 与清单 |
| Buttplug | 位于独立 protocol 测试项目，当前 Android 核心只依赖 serde/serde_json | 保留原 BSD 等声明，不声称所有 284 条都进入 APK |
| DG-LAB、Dungeonlab+pulse | 检查为设备/格式兼容引用，未把官方 APK/固件加入候选源码 | 不获得官方商标授权或背书 |
| research、截图、历史报告、部署凭据 | 被 ignore 排除 | 不打包整目录公开 |

参考项目的下载副本留在 research，其中有 CC BY-NC 和 GPL 资料；不能据此认定它们可套用 MIT。当前候选 app/core 未发现引用该目录作为构建输入，也未将其第三方中继或 SDK 整包引入。没有做能证明“所有代码从未借鉴任何片段”的完整人工溯源；如后续发现复制片段，应逐项保留许可或替换。

2026-10-15 已补充逐项阅读、参考源码片段比对和 Flutter 模板归属核对，结果及确切参考版本见 [来源复核记录](source-provenance-review.md)。本次来源复核没有发现需要从当前候选源码移除的已识别参考项目代码；这不构成对未知历史来源的保证。

`third-party-inventory.json` 是本次本地 Cargo 元数据与 Dart package config 快照，版本应与锁文件一起更新。`scripts/collect-notices.ps1` 可刷新 notices。Android Gradle/SDK、Flutter engine、操作系统组件与最终 APK 的完整依赖树不等同于该清单；正式发行时还需针对最终制品核对，不把源码清单当成全部二进制组件清单。

提示词本轮保持原样。MIT 授权不会自动改变任何云模型供应商的服务条款，也不会授权分发用户导入或他人提供的素材。
