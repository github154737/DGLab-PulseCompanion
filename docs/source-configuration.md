# 公开版与私有内测版

本文说明配置分离。用户操作见 quick-start.md，构建和签名见 building.md，发行检查见 source-release-checklist.md。

## 公开版

默认 `config/public.json`：`APP_EDITION=public`、`APP_LOGIN_ENABLED=false`、`APP_DEVELOPER_TOOLS=false`、`VENICE_TEST_ENTRY=true`。

开屏后进入服务配置，不显示内测登录。推荐导入服务提供者的连接 JSON；地址、令牌、证书自动填写，确认目标后再进入。直连时只填自己的 Venice 密钥，也支持手动填写中继。留空证书使用系统信任库，仍验证 TLS。配置只在本次进程内；退出后重新导入/填写，不读取开发者桌面密钥。可先离线浏览。证书与开发工具默认收起，导入文件不能开启开发权限或改变提示词。

`我的 → 返回服务配置` 会先取消请求、停止输出并断开设备，确认后才清理配置。中继服务需要实现项目中的请求协议，不能把任意模型 API URL 当中继；供应商 API Key 不能替代中继令牌。

```powershell
./scripts/build-public-android.ps1 -CheckOnly
# 以下命令实际生成安装包，仅在需要构建时运行
./scripts/build-public-android.ps1 -Offline
```

公开构建拒绝内测哈希、内置 API 密钥、中继 URL/令牌/证书及未知配置字段。`APP_DEVELOPER_TOOLS` 可为本机开发设置为 true；它与登录开关独立。不要在公开 JSON 中增加密钥字段。

## 私有内测版

现有云测试入口继续使用：

```powershell
./scripts/build-venice-cloud-android.ps1 -CheckOnly
# 以下命令实际生成安装包
./scripts/build-venice-cloud-android.ps1 -Offline
```

脚本默认读取仓库外的两个文件：

- `%USERPROFILE%/.aihaptics/pilot-access/login-defines.json`：管理员 SHA-256 和用户码 SHA-256 列表。
- `%USERPROFILE%/.aihaptics/venice-cloud-relay/android-defines.json`：现有云中继地址、令牌和证书。

迁移保留原管理员凭据和 5 个内测码，桌面密钥文件仍可使用。哈希文件本身也不能提交。`-PilotLoginDefines`、`-RelayDefines` 可指定其他本地文件；配置格式分别见 `config/pilot-login.example.json` 和 `config/relay.example.json`。

内测构建固定 `APP_EDITION=pilot`、`APP_LOGIN_ENABLED=true`、`APP_DEVELOPER_TOOLS=false`，管理员权限由登录身份决定，不能通过全局开发开关赋给所有内测用户。登录规则：管理员先 trim 后按大小写匹配；用户码 trim、转大写后匹配，长度 10 位。哈希对该规范化结果的 UTF-8 字节计算 SHA-256，多个用户哈希用逗号分隔。不要直接把示例占位文本用于构建。

LAN 中继和个人 Android 入口同样加载上述登录哈希；Windows Venice 构建也注入内测登录配置。缺失配置时构建会停止，不会使用共享默认密码或开放权限。

内测 APK 仍需包含原中继令牌，保留现有手机连接方式。这些安装包仍然是私有测试包；把配置放到仓库外不等于 APK 中的凭据不可提取。仓库中不会包含已配置的私有安装包。尚未引入服务端账号、额度或远程撤销。

## 部署配置

`%USERPROFILE%/.aihaptics/venice-cloud-relay/deployment.json` 保存主机、SSH 用户/端口、私钥路径和可选 HTTP CONNECT 代理；格式见 `config/deployment.example.json`。SSH 仍验证 known_hosts，不自动接受未知主机。原本机部署参数已迁入该文件，未改变服务器。

Python 部署脚本支持 `AIHAPTICS_DEPLOYMENT_CONFIG` 指定配置文件、`AIHAPTICS_CLOUD_HOME` 指定私有部署目录。服务器本地验收脚本从服务配置的 `publicUrl` 或 `AIHAPTICS_RELAY_URL` 读取地址；旧服务器未部署新配置时显式提供该环境变量即可。更新配置不会自行部署；本轮未联系服务器。

供应商密钥继续由既有中继本地/服务器配置引用，公开源码仅包含读取逻辑。私钥、供应商 Key、真实部署 JSON、登录哈希、签名凭据、录音和真实对话均不得提交。

## 手动 Flutter 构建

优先用包装脚本，因为它们执行配置检查。若手动运行 Flutter，公开版只使用 `--dart-define-from-file=config/public.json` 对应的配置（路径相对于实际工作目录）；内测版必须提供合并后的登录与中继配置。不要打印真实配置或用 verbose 构建私有包。包装脚本会拒绝 `DART_DEFINES` / `FLUTTER_TOOL_ARGS` 环境覆盖，临时定义文件在退出时删除。

代码本身还会拒绝公开版夹带私有构建配置、内测版关闭登录等错误组合。绕过构建脚本不能把开源客户端变成安全的服务端认证系统。
