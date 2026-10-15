# 源码与发行检查表

## 已实现

- [x] 公开/内测配置分离；公开默认无登录、无项目方凭据。
- [x] 原内测登录、角色、云服务及波形合集保存在外部配置中。
- [x] 部署地址、SSH、JDK 路径配置化，提供无秘密示例。
- [x] MIT、NOTICE、依赖原文/清单、资源边界记录。
- [x] 未确认分发权的波形合集不进入公开资源包；内测专用注入。
- [x] 公开版导入连接文件、单密钥直连、离线浏览。
- [x] 公开 Android 专用包名和签名；缺签名拒绝 release；内测签名路径保留。
- [x] 用户、构建/部署、隐私、贡献、安全文档。
- [x] 候选文件、小型 ZIP、实际暂存 blob、本地 Git 历史扫描。
- [x] 只读 CI 及离线 APK 检查工具；不会自动发布或部署。

## 每次发布前仍须执行

1. 查看 git status --short 和 git diff --cached，只选择需要公开的文件，不上传整个工作目录 ZIP。
   本机 Codex 辅助快照引用中可能保存改动前的敏感文件。不要使用 `git push --mirror` 或整体复制 `.git` 来公开。推荐先运行 `python scripts/export-clean-source.py D:/Public/AIHaptics-clean`（必须是新目录），从无历史的干净目录建立正式仓库；保留原工作目录供私人回溯。
2. 执行 python scripts/check-source-release.py --staged --history。历史仅覆盖本机可见 refs，发布前核对全部预期分支/tag。脚本不做图片 OCR，也无法识别所有形式的秘密。
3. 执行 scripts/test.ps1、scripts/test-build-profile.ps1、python scripts/test-source-configuration.py、python scripts/test-release-tools.py。网络、截图或真机跳过项不算通过。
4. 检查新资源来源、依赖许可证及最终二进制组件声明。不要重新带回 research 或私人波形合集。
5. 在干净机器执行公开构建并记录工具版本，备份仓库外发行签名。CI 不签名/打包。
6. 对最终 APK 执行下面的离线检查。

```powershell
python scripts/verify-public-apk.py artifacts/实际公开包名.apk --expected-signer 发行证书的SHA256 --report reports/public-apk-check.json
```

工具需要 JAVA_HOME 和 Android build-tools 36.0.0（可用 --build-tools 指定），核对签名、包名、ABI、已知秘密模式及资源包。预期指纹来自可信签名证书备份，不能从待检查 APK 现取再当作信任依据。

7. Android 真机验证安装、配置导入、退出清除、语音权限、停止/断线/重连及旧版升级；分别记录 Wi-Fi/移动网络。桌面 widget 测试不能代替真机。
8. GitHub 创建后开启 Private vulnerability reporting、分支保护和必需检查，核对 CI 实际结果。发布版本、SHA-256、已知限制和数据说明。未经明确请求不自动推送/创建 release。

本轮没有打包，所以最终 APK 扫描、全新机器完整 Android 构建及真机安装仍是发行前验证项；本地源码检查通过不等于它们已经通过。
