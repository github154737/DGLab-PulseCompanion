# 开发、构建与部署

## 环境

现有可复现脚本以 Windows + PowerShell 为目标。安装 Git、Python 3.12+、Rust 1.99.0（含 clippy/rustfmt）、Flutter 3.47.6 / Dart 3.13.5、JDK 21、Android SDK Platform/Build Tools 36 与 NDK 28.2.13676358。Windows 桌面构建还需要 Visual Studio 2022 的 C++ 桌面工作负载。Flutter 固定提交为 `5fc346839b5d0eef006ed8404392afb4dfae428d`。

把 Flutter、Cargo 放入 PATH，设置 JAVA_HOME 和 ANDROID_HOME。脚本也识别标准 Android Studio 安装路径；非标准 JDK 可在仓库外 `%USERPROFILE%/.aihaptics/build-env.json` 配置 `{"javaHome":"D:/Tools/jdk-21"}`。现有开发机配置仍保留。

```powershell
rustup target add aarch64-linux-android x86_64-linux-android
./scripts/test.ps1
python scripts/check-source-release.py --staged --history
```

脚本将 Flutter 工程复制到本机 ASCII 路径暂存，避免中文/OneDrive 路径构建问题。Cargo.lock 与 app/pubspec.lock 必须保留；依赖齐全后可加 `-Offline`。自动检查不调用付费模型 API、不接触实物、不生成 APK。需要网络/真机的测试默认跳过，不能把跳过计为验收通过。

如系统已有旧 JAVA_HOME（例如 JDK 11），请在当前终端改为 JDK 21；显式环境变量优先于本地默认配置。直接运行 gradlew 会使用 JAVA_HOME，Flutter 自己检测到的 JDK 不一定与它相同。

检查干净源码可先执行 `python scripts/export-clean-source.py D:/Public/AIHaptics-clean`，再在新目录运行 `scripts/test.ps1`。只导出已审查的当前候选文件，不复制原 `.git`、私有配置和制品。使用同一电脑的 SDK 缓存做此检查不等于在全新机器完成 Android 编译。

## 公开版

普通使用者直接安装发布的 APK，不需要编译。维护者第一次发行时建立独立签名身份：

```powershell
./scripts/init-release-signing.ps1
./scripts/build-public-android.ps1 -CheckOnly
# 下面才会真正构建 APK：
./scripts/build-public-android.ps1
```

签名密钥和随机口令保存在仓库外 `.aihaptics/release-signing/`，目录限制为当前 Windows 用户和 SYSTEM。妥善备份整个目录；不能丢失后直接换钥升级已安装的应用。也可通过 AIHAPTICS_SIGNING_PROPERTIES 指向已有外部 properties（storeFile/storePassword/keyAlias/keyPassword），默认生成过程不会覆盖现有文件。

公开版包名为 `dev.aihaptics.haptics_lab.community`，可与内测版共存。公开 release 缺少签名就终止，不回退调试签名。公开资源包不含私人波形合集。`-CheckOnly` 只验证配置，不验证签名、Gradle 编译或安装效果。

公开 Windows 开发构建可运行 `scripts/build-windows.ps1 -Release`；Windows 安装器签名与公证不在本轮实现范围。Android 是当前分发目标。

## 保持当前内测版

```powershell
./scripts/build-venice-cloud-android.ps1 -CheckOnly
# 需要打包时才运行：
./scripts/build-venice-cloud-android.ps1
```

原登录、云配置分别由 `.aihaptics/pilot-access/login-defines.json` 与 `.aihaptics/venice-cloud-relay/android-defines.json` 读取。波形合集从 `.aihaptics/pilot-assets/user-waveforms.zip` 注入暂存区；缺失时中止，不静默生成缺资源内测包。内测包继续使用原包名和现有调试签名，避免破坏现有升级路径。不要把内测包作为公开发行包。

## 自建云中继（维护者一次配置）

不需要先搭局域网中继。以下会修改所选择的服务器，应用用户无需执行。

1. 准备专用 Ubuntu 24.04 x64 服务器、公网 HTTPS 可达地址及 SSH 密钥。通过供应商控制台核验 SSH 主机指纹，再连接一次以写入本机 known_hosts。脚本拒绝未知主机，不自动信任任意主机。
2. 将 `config/deployment.example.json` 复制到 `%USERPROFILE%/.aihaptics/venice-cloud-relay/deployment.json`，填写 host、ssh_user、ssh_port、ssh_key。直连 SSH 时 proxy_host 为空、proxy_port 为 0。当前部署脚本要求 root 权限及专用服务器。
3. 上传并在服务器以 root 执行 `scripts/cloud-relay-bootstrap.sh`。它安装 Dart、nginx、防火墙，只允许 SSH/443；不要用于承载其他业务的服务器而不审查其变更。
4. 将自己的 Venice 密钥写入仓库外文本文件，安装部署依赖 `python -m pip install paramiko`，运行：

```powershell
python scripts/deploy_cloud_relay.py --key-file D:/Private/venice-key.txt
python scripts/verify_cloud_relay.py --report reports/cloud-readiness.json
python scripts/export-connection.py
```

部署脚本使用已核验 SSH 上传独立 Dart 中继，启用 systemd/nginx/TLS，并取回绑定证书的客户端配置。已有身份不随意覆盖。验证脚本默认只做非付费检查，只有显式 `--paid` 才测试付费接口。连接文件已含自签证书，用户无需安装系统根证书。测试期可使用该方式；证书到期/更换后须重新导出连接文件并分发。

当前是共享令牌、单实例的小规模测试中继，不是账户计费平台。手机 → 中继的可达性必须在目标用户网络实测；服务器能访问 Venice 不保证每条国内网络到服务器都畅通。

## CI 和发布

`.github/workflows/check.yml` 使用只读权限、固定 action 提交，不携带服务凭据；检查暂存/本地完整历史、配置、Rust 与 Flutter。不会签名、打包、自动发布或部署。它需要仓库上传 GitHub 后才能真正运行；本地通过不能冒充远程 CI 通过。

发行前执行 `docs/source-release-checklist.md`。固定源码和锁文件能提高可复现性，但本轮不宣称 APK 字节级可复现。
