# iOS OpenID 配置与验收

0.2.0 复用现有 Reborn OpenID 客户端。官方网页登录继续在论坛 WebView 中完成；Reborn 身份与水印绑定另走系统授权窗口。两个窗口可能登录不同账号，绑定时必须校验 UID 一致。

## 后台配置

用户于 **2026-10-19** 确认已追加并成功保存以下回调：

```text
org.cc98.reborn.shell:/oauth/callback
```

冒号后只有一个斜杠，末尾没有斜杠。保留原有浏览器扩展回调和 `https://www.cc98.org/`；现有 CORS 来源保持不变。App 通过原生网络接口兑换授权码，不把 App scheme 当成浏览器 CORS 来源。

| 配置 | 本版使用值 |
| --- | --- |
| Client ID | `9ca359c2-4112-44de-6177-08debd80dfb1` |
| 授权端点 | `https://openid.cc98.org/connect/authorize` |
| 令牌端点 | `https://openid.cc98.org/connect/token` |
| 资料端点 | `https://api.cc98.org/me` |
| 授权方式 | Authorization Code + PKCE S256 |
| Scope | `openid profile cc98-api read-user-info` |
| 强制 PKCE | 开启 |
| 允许明文 PKCE | 关闭 |
| 要求客户端密钥 | 关闭 |
| 允许通过浏览器获得访问令牌 | 关闭；回调只接收授权码 |

自签安装不需要另建授权服务器或购买域名。重签时保留 App 的 URL scheme；回调白名单和 App 接收地址必须完全一致。公开分发时，再确认现有客户端用途与站方分发要求。

## 绑定怎么完成

1. 先在原站模式登录 CC98，再切换到 Reborn 模式。
2. 点击页面的“绑定同一账号”。App 用 `ASWebAuthenticationSession` 打开官方授权窗口。
3. App 为本次流程生成随机 state 和 PKCE verifier，校验精确回调与 state 后，用相同 redirect URI 和 verifier 兑换授权码。
4. 临时 access token 只用于官方 `/me`。返回的 UID 必须与授权前及保存前的网页账号一致，且存在有效 `watermarkId`。
5. 仅保存可信身份与水印摘要，并通知 Reborn 页面。不会导入桌面 token，不持久保存 access/refresh token，也不把网页登录凭据导出给原生层。

普通绑定通过 `/me` 确认身份，不使用未经验证的 ID Token 声明。缺 UID、水印或账号不匹配时不能写入成功状态；不以缺少水印的 userinfo 回退放行。

## 真机需要确认的路径

- **同账号成功**：授权窗口返回 App，绑定提示消失，水印正确，未提交内容不因绑定被重载。
- **取消后重试**：关闭授权窗口后仍未绑定，论坛登录和编辑内容保留，再次点击可以重新授权。
- **错账号拒绝**：系统窗口使用另一账号时不绑定；再次点击绑定会要求重新登录并同意授权，选择与网页相同的账号后才通过。
- **中途换页或换号**：过期流程不能给新页面或新账号写入旧绑定。
- **重启恢复与本地解绑**：重启后读取可信摘要；解除绑定后恢复绑定提示，但不退出论坛账号。
- **网络错误**：VPN 不覆盖系统授权窗口或原生请求时，显示错误并允许恢复网络后重试；不复制错误中的 token、回调或正文到诊断。
- **续签**：按原方法重签后，系统窗口仍能通过相同 scheme 返回 App。

后台成功保存回调只确认配置已提交；上述真实授权闭环由用户在 iPhone 16 Pro / iOS 26.5.2、校网或系统 VPN 下完成。云构建不使用论坛账号或 Apple 凭据。

## 问号仍是独立接入

本版不接入问号授权。继续使用同一个 client ID 有利于沿用服务端 audience 配置，但问号仍需要独立用户同意、服务端 challenge nonce、重新取得并验证 ID Token，以及对 `sub` 和历史记录连续性的确认。现有服务会话有效期为 15 分钟，不假设 iOS 可以静默续期。
