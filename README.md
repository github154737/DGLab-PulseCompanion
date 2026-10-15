# AI Haptics

Flutter + Rust 的对话与设备交互项目，包含文字/语音对话、持续语音、GLM 控制规划与导答、Venice 回复、DG-LAB 连接和执行回执。

当前正在进行开源整理，尚未正式发布。原有私有内测版继续使用现有登录和云中继；公开构建不附带项目方云服务或登录凭据。

## 最简单的使用方式

- 受邀内测用户：安装维护者给的内测包，输入原内测码即可。
- 公开版用户：导入服务提供者给的连接 JSON，核对地址后进入；无需手动填写证书。自己直连 Venice 时只填一个 API 密钥。
- 无配置也可离线浏览。公开版无登录，开发功能默认关闭；配置仅在本次运行内保留。

先读 [用户快速开始](docs/quick-start.md)。只有维护者需要 [构建和部署](docs/building.md)。

## 配置与构建入口

- [公开版、内测版配置说明](docs/source-configuration.md)
- [源码提交与发布检查表](docs/source-release-checklist.md)
- [来源复核与首次公开提交范围](docs/source-provenance-review.md)
- `config/public.json`：无凭据的公开构建配置。
- `config/*.example.json`：私有配置格式示例；复制到仓库外再填写。
- `scripts/build-public-android.ps1 -CheckOnly`：仅检查公开构建配置。
- `scripts/build-venice-cloud-android.ps1 -CheckOnly`：仅检查已有内测配置。
- `scripts/check-source-release.py`：检查候选提交文件，不创建提交或联系 GitHub。

去掉 `-CheckOnly` 才会实际构建 Android 安装包。公开 release 要求独立签名，包名与内测版分离，且不包含私人波形合集。正式发行前仍须完成安装包扫描和真机验收。

## 工程布局

- `app/`：Flutter 界面、Android/Windows 平台代码，以及 Dart 中继。
- `core/`：Rust 控制核心。
- `protocol/`：隔离协议测试。
- `scripts/`：配置、构建、部署和检查工具。
- `docs/third-party/`：第三方许可证原文。

实物输出必须由使用者显式启用。停止、断线保护、强度上限和迟到请求拦截独立于模型与登录配置。软件测试通过不等于所有手机、网络或实体设备均已验证。

自有代码使用 [MIT](LICENSE)；第三方内容见 [NOTICE](NOTICE.md)、[资源整理记录](docs/resource-audit.md) 和 [依赖清单](docs/third-party-inventory.json)。本项目不是 DG-LAB 官方应用，不代表获得官方背书。

[数据与隐私](docs/privacy.md) · [参与贡献](CONTRIBUTING.md) · [漏洞报告](SECURITY.md)。CI 只做检查，不自动发布安装包或部署服务器。
