<p align="center">
  <img src="docs/images/pulse-companion-catgirl.png" width="880" alt="白毛猫娘展示 PulseCompanion 的互动界面，郊狼设备固定在腿部衣物外侧" />
</p>

<h1 align="center">🐾 DGLab-PulseCompanion</h1>

<p align="center">
  <b>让对话，有一点点触感。</b><br />
  一个会陪你聊天、听你说话，也能连接郊狼的小伙伴。
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-A9586D" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/Android-7.0%2B-EACAD2" alt="Android 7.0+" />
  <img src="https://img.shields.io/badge/Made_with-Flutter_%26_Rust-C89AA8" alt="Flutter and Rust" />
</p>

<p align="center">
  <a href="#install">安装 APP</a> ·
  <a href="#getting-started">开始使用</a> ·
  <a href="#build">自己构建</a> ·
  <a href="https://github.com/github154737/DGLab-PulseCompanion/issues">反馈与许愿</a>
</p>

---

## 🌸 你好呀，这里是 PulseCompanion

有时候，比起点来点去，我们更想直接说一句：「轻一点」「A 调到 10，B 不变」，或者就聊聊天。

**PulseCompanion** 把文字聊天、连续语音和 DG-LAB 设备交互放进了同一个 APP。你可以打字，也可以开口说话；想打断她时，开启「开口打断」就好。波形、强度和执行结果也能在页面上看到，不用全靠猜。

这是一个还在慢慢长大的开源项目。界面是软乎乎的奶油白和豆沙粉，功能则希望一点点打磨到顺手。欢迎来玩，也欢迎带着问题和新点子来敲门。ฅ^•ﻌ•^ฅ

## ✨ 她现在会些什么？

| 小本领 | 可以这样玩 |
|---|---|
| 💬 文字聊天 | 聊天、调整设备，在同一段对话里完成 |
| 🎙️ 连续语音 | 说话、停顿、发送；开启开口打断后，可以在朗读时插话 |
| 🧠 双模型配合 | GLM 整理意图、控制计划和导答建议，Venice 聊天模型组织回复 |
| 🎛️ 双通道控制 | 分别调整 A / B，自己设置最高强度和单次增幅 |
| 🌊 波形小窝 | 预览、收藏、导入与导出波形；实物输出目前使用支持的内置波形 |
| 🔗 郊狼配对 | 从 APP 打开 DG-LAB 配对，也可以通过二维码连接 |
| 🧾 看得见的回执 | 这轮调了什么、有没有执行，聊天里都有记录 |

<a id="install"></a>

## 📱 先把小伙伴装进手机

> **公开 APK 还在准备中。** 目前这里发布的是源码，[Releases 发布页](https://github.com/github154737/DGLab-PulseCompanion/releases)暂时没有安装包。准备好后，公开 APK 会放在那里。
>
> 已经受邀参加内测的小伙伴，继续使用维护者发给你的 APK 和内测码即可。想现在自己动手，可以跳到下面的[源码构建](#build)。

### 拿到 APK 后，这样安装就好

1. 把 `.apk` 文件下载或传到 **Android 手机**上。
2. 在下载列表或文件管理器里点开它。如果系统询问安装权限，允许当前浏览器或文件管理器安装应用，再继续安装。
3. 打开 APP，跟着下面的「第一次见面」配置服务，就可以开始了。

目前面向 Android，代码最低要求为 **Android 7.0**，安装包支持 **ARM64 / x86_64**，不含 32 位 ARM。iPhone 暂时没有安装包，Windows 开发构建入口见[构建文档](docs/building.md)。

**小提醒：** GitHub 的 `Code → Download ZIP` 和 Releases 里的 `Source code` 都是源码，不能当作 APK 安装哦。

<a id="getting-started"></a>

## 🫶 第一次见面，怎么开始？

### ① 给她接上聊天服务

公开版没有内测码登录，打开后按你手边的材料选一个：

| 你手里有什么？ | 怎么做 |
|---|---|
| 服务提供者给的连接 JSON | 点「导入连接文件」→ 核对服务器地址 →「进入应用」 |
| 自己的 Venice API Key | 填入密钥 →「进入应用」；手机网络需要能访问 Venice |
| 还没准备好，只想先看看 | 点「先离线浏览」，逛逛界面和波形 |

受邀内测版仍然使用原来的内测码，无需自己填写服务配置。公开版不附带免费 API 额度，费用由你使用的服务账户承担。

当前服务配置只在这次运行中保留，重启后需要重新导入或填写。连接 JSON 里有访问令牌，像密码一样收好，别发到公开 Issue 里。

### ② 和你的郊狼认识一下

1. 准备好 **郊狼 3.0 和 DG-LAB 官方 APP**，先在官方 APP 里连接蓝牙设备。
2. 回到 PulseCompanion，进入「互动」→「连接设备」。
3. 按提示打开 DG-LAB 配对；如果手机的浏览器跳转不顺利，可以改用配对二维码。
4. 配对完成后，回到 PulseCompanion，**选择对应设备，再启用实物输出**。

没有设备也可以先体验聊天和波形预览。有设备时，先设好上限，从低强度开始，确认「停止全部」可以正常使用。

### ③ 开始聊天吧

去「聊天」页打字，或者打开连续对话。想让她调整设备，就把意图说清楚；想安静一会儿，随时静音或结束对话。

使用可访问的**云中继**时，手机不需要和电脑连同一个 Wi-Fi，电脑也不用一直开着。能否顺畅连接仍取决于手机网络；Wi-Fi 不顺时，可以用移动网络对比一下。

<a id="build"></a>

## 🧩 给喜欢动手的小伙伴

目前的构建脚本以 **Windows + PowerShell** 为主。先按[构建文档](docs/building.md)准备 Git、Python、Flutter、Rust、JDK 和 Android SDK，再运行：

```powershell
git clone https://github.com/github154737/DGLab-PulseCompanion.git
cd DGLab-PulseCompanion

rustup target add aarch64-linux-android x86_64-linux-android

# 第一次构建时创建自己的签名；已有签名就跳过这一行
./scripts/init-release-signing.ps1

# 先检查配置，再真正构建 APK
./scripts/build-public-android.ps1 -CheckOnly
./scripts/build-public-android.ps1
```

完成后到 `artifacts/` 找 `AIHaptics-<版本号>-public-android.apk`，传到手机安装即可。签名文件保存在仓库外，请留好备份，后续升级还要用它。

公开版与内测版使用不同包名，可以共存。公开版不带维护者的密钥、云服务权限或私人波形合集。

<details>
<summary>🔧 想看更多：模型配合、自建服务和项目结构</summary>

GLM 负责理解当前轮次、给出控制计划和聊天建议；APP 本地检查并执行设备操作，再把执行回执交给 Venice 聊天模型生成回复。导答建议帮助她接住话题，实物输出仍经过本地规则与用户授权。

已经有云中继的维护者，可以导出一个连接文件，交给受邀用户导入：

```powershell
python scripts/export-connection.py
```

这个命令需要已有的外部中继配置。完整步骤见[构建与部署](docs/building.md)，连接文件的使用方法见[快速开始](docs/quick-start.md)。

| 目录 | 里面住着什么 |
|---|---|
| `app/` | Flutter 界面、语音、设备连接和中继服务 |
| `core/` | Rust 控制核心 |
| `protocol/` | 协议测试 |
| `scripts/` | 构建、部署与检查工具 |
| `docs/` | 使用说明、配置和来源记录 |

[公开版配置](docs/source-configuration.md) · [参与贡献](CONTRIBUTING.md) · [发布检查表](docs/source-release-checklist.md)

</details>

## 🐱 几个你可能会问的小问题

**需要自己租服务器吗？**  
有可用的连接文件就不需要。也可以使用自己的 Venice 密钥直连；想给朋友提供服务，再考虑自建中继。

**导入的波形都能直接用于实物吗？**  
目前导入主要用于预览与导出，实物输出使用支持的内置波形。公开仓库也没有附带私人波形合集。

**她说「调好了」，就一定执行了吗？**  
以页面上的执行回执和设备实际状态为准。模型的聊天文字不能代替执行结果。

**发现小毛病，或者有想加的功能？**  
欢迎[开一个 Issue](https://github.com/github154737/DGLab-PulseCompanion/issues)。写上 APP 版本、手机型号和复现步骤就很有帮助；截图前记得藏好密钥和私人聊天内容。

## 🤍 轻轻提醒一下

本项目面向成年人，是独立社区项目，与 DG-LAB 官方没有隶属或背书关系。使用设备请遵循官方说明，先设置合适的上限，从低强度开始；需要停止时，直接用「停止全部」。

软件还在迭代，不同手机与网络的表现可能不同。数据说明在[这里](docs/privacy.md)，涉及密钥或漏洞的问题请走[非公开反馈](SECURITY.md)。

## 🌷 致谢与许可

感谢 Flutter、Rust、DG-LAB 公开协议，以及所有让这个小项目长大的开源工具。

自有代码采用 [MIT](LICENSE)，第三方内容保留各自许可，详见 [NOTICE](NOTICE.md) 与[来源记录](docs/source-provenance-review.md)。

<p align="center">如果这个小伙伴让你觉得有点可爱，欢迎留下一颗 ⭐<br />我们慢慢把她养大。</p>
