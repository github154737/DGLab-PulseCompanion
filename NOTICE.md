# 版权与来源说明

项目自有代码与文档按根目录 LICENSE（MIT）授权。第三方代码、图标和依赖继续适用各自的许可证；项目 MIT 不替换其条款。

- Flutter、Dart 包及 Rust 依赖：原文位于 `docs/third-party/`，本次解析清单位于 `docs/third-party-inventory.json`。应用内 Flutter 许可注册与 Rust notices 保留。
- Flutter 生成的平台工程骨架（尤其 `app/windows/runner/` 的窗口、工具函数与启动模板）来源于 Flutter，适用其 BSD 条款；版权与原文见 `docs/third-party/Flutter-LICENSE.txt`，不将这些模板重新声称为本项目原创 MIT 代码。
- DG-LAB / 郊狼、Dungeonlab+pulse 是设备、协议和文件格式的兼容性说明，不表示获得官方认证或商业合作。未将官方应用或设备固件随源码分发。
- `research/` 是本机研究资料，不是本项目源码发行内容。其中其他项目的代码、GPL 中继及非商用许可资料不适用本项目 MIT，也不能随本项目直接重新许可。
- `app/assets/user-waveforms.zip` 的公开版本只含说明文件。来源未完整确认的私人波形合集已移出候选源码；用户自行导入的文件仍由原作者决定许可。
- `app/lib/pulse_library.dart` 提供两个内置波形及格式读取逻辑。兼容导入格式不代表取得任意同格式波形文件的分发权。

逐项来源复核、参考版本与范围见 `docs/source-provenance-review.md`，资源整理边界见 `docs/resource-audit.md`。如果发现来源或署名问题，请按 SECURITY.md 的非公开联系方式提供文件和依据。
