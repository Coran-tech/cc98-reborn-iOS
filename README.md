# CC98 Reborn iOS 真机验证壳

在 iPhone 上直接打开 CC98 原站，并从 App 包加载固定版本的 Reborn。没有页面代理服务器；原站登录、权限、编辑和上传继续由官方网页执行。

本轮验证设备是 **iPhone 16 Pro / iOS 26.5.2**，最低支持 iOS 17。验证壳不是完整移植版：保留现有同账号 OpenID 绑定门槛，尚未配置原生授权；先验证原站流程、包内注入与原站模式恢复。

## 从 Windows 取得 iPhone 候选包

1. 在 [GitHub Actions](https://github.com/Coran-tech/cc98-reborn-iOS/actions/workflows/ios-shell.yml) 打开 `iOS verification shell`。
2. 选择验证分支运行工作流。默认先跑本轮 Node 测试和 iOS Simulator 测试，再编译 **iPhoneOS arm64** 应用。若要先取得真机候选包，可勾选 `device_only`：保留 Node 测试、设备编译和包校验，明确跳过模拟器启动与测试。
3. 构建成功后下载 `ios-shell-运行编号-尝试次数` artifact。默认产物为 `CC98RebornShell-unsigned-device.ipa`；`device_only` 产物为 `CC98RebornShell-unsigned-unverified-device.ipa`，**尚未完成模拟器验证，不能据此认定 App 能启动或功能可用**。同包的 `README.txt`、`build-status.txt` 记录实际验证状态。
4. 按 [AltStore Windows 官方指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) 在本机配置签名工具，把候选 IPA 用自己的 Apple Account 签名安装。Apple Account 密码、验证码不交给本项目或云构建。
5. iPhone 开启开发者模式，并连接校网或能覆盖本 App 的系统 VPN，然后按 [真机检查表](https://github.com/Coran-tech/cc98-reborn-iOS/blob/codex/ios-verification-shell/ios/DEVICE_TEST_CHECKLIST.md) 验证。

**下载的 IPA 尚未签名，不能直接安装。** 免费个人签名通常 7 天到期，需要续签；Windows 编写代码不等于 Windows 能编译 iOS SDK。云端不使用 Apple 分发凭据，也不会访问论坛账号或学校 VPN。

## 本地检查与云构建

Windows 安装 Node.js 22 后，在仓库根目录运行：

```powershell
node --test tests/ios-*.test.cjs
node scripts/package-ios-resources.cjs
```

脚本按 manifest 与资源引用白名单打包 Reborn，生成的资源不提交到仓库。macOS 构建采用 XcodeGen 生成工程，GitHub Actions 和备用 Codemagic 共用同一构建入口：

```sh
bash scripts/build-ios-shell.sh
```

该脚本需要匹配配置的 macOS/Xcode 环境，不能在 Windows 上生成 iPhone 可执行程序。默认流程要求模拟器测试、设备编译及包校验都通过，并保留日志、xcresult 和截图。

需先取得未经模拟器验证的设备候选时，显式运行 `bash scripts/build-ios-shell.sh --device-only`。该路径不生成模拟器测试结果；设备编译或包校验失败仍不会产出 IPA。它不改变后续完整验证要求，也不改变原站登录及同账号绑定边界。

GitHub 工作流只在 `codex/ios-verification-shell` 的相关文件变动或手动触发时运行，使用标准 macOS runner。没有自动 TestFlight 上传、App Store 发布或 Release 创建。Codemagic 只保留手动备用配置，不需要同时启用两套 CI。

## 壳内操作

- **原站模式**：不注入 Reborn，适合先验证官方登录、编辑和上传。
- **Reborn 模式**：从包内按固定顺序注入增强脚本、样式和资源；不执行远程 Reborn 更新。
- **切换与重载**：可能中断当前网页的未提交编辑，必须确认；操作前自行保存重要草稿。模式切换保留同一网站数据仓库，不顺便清除登录。
- **诊断**：区分容器状态、注入状态和不支持能力。诊断不应包含帖子正文、密码、Cookie、token 或完整 OAuth 回调。

“已注入”不代表“已绑定”。当前插件登录后要求同 UID 的可信 OpenID 摘要和水印；该条件未接入前，不能把登录后的增强编辑体验记为通过。需要站方确认的内容单独列在 [OpenID 接入条件](https://github.com/Coran-tech/cc98-reborn-iOS/blob/codex/ios-verification-shell/ios/OPENID_PREREQUISITES.md)。

## 本轮边界

- 只对精确登记的官方 HTTPS 主页面启用增强与有限原生桥。外部页面、OpenID 页面和未登记子框架不获得特权。
- 先验证主页面；侧窗子框架的完整增强、浏览器后台服务、问号、AI 和本地语义服务尚未作为本轮交付。
- 官方网页业务请求保留在网页身份边界；不把论坛 Bearer 提取到 Swift，不暴露任意网络、文件或脚本执行能力。
- 云端离线 UI smoke 只验证容器控件和恢复交互，不代表真实校园网络、登录、上传或 iOS 26.5.2 真机已经通过。
- 原站模式是故障恢复手段，不是完整 Reborn 功能验收的替代品。App 后台可被系统挂起，不承诺后台持续扫描或离线推送。

## 源码与后续更新

此仓库包含验证壳和构建所需的 Reborn 资源源码快照，来源于 [CC98 Reborn](https://github.com/Coran-tech/cc98-reborn) 当前 0.4.1 工作副本。资源版本以本库快照为准，不假定等同上游已发布的同名 tag。只同步打包器列出的输入，不复制服务器、凭据、真实论坛运行数据或整个开发目录。

App 更新通过重新构建和自签完成。转 TestFlight 时若 Bundle ID 或数据容器改变，应按新安装处理；现有配置备份不含草稿、稍后再看或登录凭据。

保留 Reborn MIT 许可与 Showdown、KaTeX 等包内依赖许可。独立 App 的内容、品牌与分发许可，以及 OpenID 客户端用途，仍按相应服务方要求确认。
