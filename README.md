# CC98 Reborn 原生 iOS 客户端

基于 DeepSeek 原生分支的非官方 CC98 客户端，使用 SwiftUI 提供首页、版面、新帖、消息、我的五个入口，直接访问 CC98 API。**需要校网或覆盖 App 与系统授权窗口的系统 VPN；不提供公网代理。**

当前开发分支为 `codex/ios-mobile-ui`，版本 **0.4.0 / Build 100**，已通过完整云构建与 8 条原生界面流程。在 Build 82 长时登录版上整理手机界面，并接入版面／联系人置顶、用户备注、私信草稿、草稿中心、搜索历史、稍后再看管理及本机增强备份。真实授权、中文输入、上传与跨有效期续期仍按真机清单验证。

## 安装与使用

- [当前版本说明与安装步骤](ios/README.md)：候选 IPA、构建状态、Windows 自签、功能范围与数据边界。
- [真机验证清单](ios/DEVICE_TEST_CHECKLIST.md)：以 **iPhone 16 Pro / iOS 26.5.2** 验证登录、中文输入、上传、草稿与续期；App 最低支持 iOS 17。
- [OpenID 配置与限制](ios/OPENID_PREREQUISITES.md)：官方授权、回调及需要站方配合的条件。
- [手机端 UI 设计规范](ios/MOBILE_UI_SPEC.md)：页面、交互、功能保留、已接入能力与后续范围。

登录从“我的”进入官方 OpenID 系统授权窗口，不需要先在内嵌网页登录或进行旧壳同账号绑定。凭据按账号存入本机 Keychain；自动续期受实际刷新授权与站方策略约束，不承诺永久登录。

IPA 需自行签名后安装。沿用已成功使用的 Windows 签名方式，优先保持原签名身份和 Bundle ID 覆盖安装，不要先卸载含有草稿的版本。Apple Account、密码与验证码只在你信任的签名工具中输入，不交给本项目或云构建。也可参考 [AltStore Windows 官方安装指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)。

## 检查与云构建

Windows 可运行仓库的 Node 检查；iOS SDK 编译在 macOS 完成。完整步骤、实际测试范围与设备包说明见 [开发与云构建说明](ios/README.md#windows-检查与云构建)。

- [GitHub Actions](https://github.com/Coran-tech/cc98-reborn-iOS/actions/workflows/ios-shell.yml) 提供手动构建，下载对应分支的 artifact。
- 构建入口为 [`scripts/build-ios-shell.sh`](scripts/build-ios-shell.sh)，产物的 `README.txt`、`build-status.txt`、日志和截图记录实际验证结果。
- `device_only` 只生成未经模拟器验证的设备候选，不能作为本轮 UI 验收依据。
- 云端使用合成数据，不接入真实论坛账号或学校 VPN，也不自动发布 Release、上传 TestFlight。

## 数据范围与未接入能力

本机增强备份只包含置顶、用户／主题备注、屏蔽规则及稍后再看；不含凭据、草稿、私信正文、搜索／浏览历史、阅读进度和外观设置。重要草稿请另行复制保存，不能把该文件当作完整设备迁移。

问号、AI、本地语义服务、远程推送和部分桌面增强仍待独立接入。前台本地消息提醒不等于应用关闭后的推送。

仓库保留 `ShellView`、网页注入资源及同账号绑定代码作为历史兼容实现，**当前 App 入口为 `NativeRootView`，不提供旧壳的原站／Reborn 模式切换**。旧壳的 HTTPS 页面嵌入本地过滤 iframe 受 WebKit 混合内容规则限制，测试中明确记录为已知兼容失败；不代表旧网页过滤已经可用。历史壳的安装反馈不能替代本版原生验收。

## 来源与许可

项目保留 [CC98 Reborn](https://github.com/Coran-tech/cc98-reborn) 0.4.1 工作副本的资源源码快照及 [MIT 许可](LICENSE)，并保留 Showdown、KaTeX 等包内依赖许可。旧壳资源按本仓库快照打包，不执行远程 Reborn 更新；不假定快照等同上游同名发布版本。

内容、品牌、公开分发和 OpenID 客户端用途仍按相应服务方要求确认。
