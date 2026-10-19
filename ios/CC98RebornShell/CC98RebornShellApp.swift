import SwiftUI
import WebKit
import SafariServices
import Combine

@main
struct CC98RebornShellApp: App {
    @StateObject private var model = ShellModel()
    var body: some Scene { WindowGroup { ShellView(model: model) } }
}

struct BrowserSurface: UIViewRepresentable {
    let browser: WKWebView
    func makeUIView(context: Context) -> WKWebView { browser }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ShellView: View {
    @ObservedObject var model: ShellModel
    private let accent = Color(red: 0.05, green: 0.38, blue: 0.31)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.mode == .original ? "globe" : "sparkles").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.mode.title).font(.headline).accessibilityIdentifier("modeLabel")
                    Text(model.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("开发验证").font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(accent.opacity(0.09), in: Capsule()).foregroundStyle(accent)
                Button { model.sheet = ShellSheet(content: .diagnostics) } label: { Image(systemName: "info.circle").frame(width: 36, height: 36) }
                    .accessibilityLabel("状态与诊断").accessibilityIdentifier("diagnosticsButton")
            }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)

            if model.isLoading { ProgressView(value: model.progress).tint(accent).accessibilityLabel("页面加载进度") }
            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 9) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("networkError")
                    HStack {
                        Button("重试") { model.request(.reload) }.accessibilityIdentifier("retryButton")
                        if model.mode == .enhanced {
                            Button("恢复原站") { model.request(.mode(.original)) }.accessibilityIdentifier("restoreOriginalButton")
                        }
                    }.buttonStyle(.bordered)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.12))
            }
            if model.mode == .enhanced {
                Text("增强需同账号 OpenID 绑定与可信水印。授权在系统窗口完成；随时可切回原站。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.04))
                    .accessibilityIdentifier("enhancedNotice")
            }
            if let browser = model.webView { BrowserSurface(browser: browser).id(model.viewID) }
            else { ContentUnavailableView("网页尚未创建", systemImage: "globe", description: Text("请关闭并重新打开 App。")) }

            HStack(spacing: 2) {
                Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left").frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(!model.canGoBack).accessibilityLabel("后退").accessibilityIdentifier("backButton")
                Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right").frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(!model.canGoForward).accessibilityLabel("前进")
                Button {
                    if model.isLoading { model.stopLoading() }
                    else { model.request(.reload) }
                } label: { Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityLabel(model.isLoading ? "停止加载" : "重新加载").accessibilityIdentifier("reloadButton")
                Button { model.request(.mode(model.mode == .original ? .enhanced : .original)) } label: {
                    VStack(spacing: 2) { Image(systemName: "rectangle.on.rectangle"); Text(model.mode == .original ? "试用增强" : "恢复原站").font(.caption2) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityIdentifier("modeToggleButton")
                Menu {
                    Button("返回 CC98 首页", systemImage: "house") { model.request(.home) }
                    Button("分享当前地址", systemImage: "square.and.arrow.up") {
                        if let url = model.webView?.url { try? model.share([url]) }
                    }.disabled(!ShellPolicy.isWebURL(model.webView?.url))
                    Button("状态、下载与诊断", systemImage: "list.bullet.rectangle") { model.sheet = ShellSheet(content: .diagnostics) }
                } label: { Image(systemName: "ellipsis").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityLabel("更多")
            }.padding(.horizontal, 8).padding(.vertical, 3).background(.bar).tint(accent)
        }
        .background(Color(uiColor: .systemBackground))
        .alert(item: $model.pendingAction) { action in
            Alert(title: Text("先确认未提交内容"), message: Text(action.detail), primaryButton: .destructive(Text("继续"), action: { model.perform(action) }), secondaryButton: .cancel(Text("取消")))
        }
        .sheet(item: $model.sheet, onDismiss: { model.sheetDismissed() }) { sheet in
            switch sheet.content {
            case .diagnostics: DiagnosticsView(model: model)
            case .safari(let url): SafariSurface(url: url)
            case .share(let items): ShareSurface(items: items)
            case .popup(let browser): PopupView(model: model, browser: browser)
            }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: ShellModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnbind = false
    var body: some View {
        NavigationStack {
            List {
                Section("当前状态") {
                    LabeledContent("模式", value: model.mode.title)
                    LabeledContent("本地 Reborn", value: model.extensionVersion)
                    Text(model.status)
                    Text(model.runtimeState)
                    if let issue = model.assetIssue { Text(issue).foregroundStyle(.orange) }
                    if let issue = model.settingsIssue { Text(issue).foregroundStyle(.orange) }
                }
                Section("验证边界") {
                    Text("这是非官方开发验证壳。页面已加载、脚本已安排或收到报告，都不代表登录、绑定、编辑或上传通过。")
                    Text("App OpenID 仅保存经 /me 验证的同账号与水印摘要，不保存授权令牌。问号服务、完整侧窗和嵌入式插件设置仍未接入。")
                    Text("iOS 使用系统文件选择器。请在原站模式手动测试编辑、照片与文件上传；取消选择不能触发提交。")
                }
                Section("同账号 OpenID 绑定") {
                    Text(model.authStatus).accessibilityIdentifier("authStatus")
                    Text("请先在论坛登录，再进入增强模式授权。解除本机绑定不会退出论坛，也不会撤销 CC98 授权。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.authBusy {
                        Button("取消当前授权", role: .cancel) { model.oauth.cancel(.cancelled) }
                    } else {
                        Button(model.authBound ? "重新验证绑定" : "绑定当前网页账号") { model.retryBinding() }
                            .disabled(model.mode != .enhanced || model.isUITesting)
                    }
                    Button("解除本机绑定", role: .destructive) { confirmUnbind = true }
                        .disabled(!model.authBound)
                }
                if !model.completedDownloads.isEmpty {
                    Section("本次下载（临时文件）") {
                        ForEach(model.completedDownloads, id: \.self) { file in
                            ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                Section("脱敏诊断 · 最近 100 条") {
                    Text("不记录网址路径、查询参数、账号、正文、令牌或原始异常。仅本机保存本次运行记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.diagnostics.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(entry.event).font(.system(.caption, design: .monospaced)); Spacer(); Text(entry.time, style: .time).font(.caption2).foregroundStyle(.secondary) }
                            if !entry.details.isEmpty { Text(entry.details).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.navigationTitle("状态与诊断").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .alert("解除本机绑定？", isPresented: $confirmUnbind) {
                    Button("取消", role: .cancel) {}
                    Button("解除", role: .destructive) {
                        let result = model.oauth.logout()
                        if result["ok"] as? Bool != true { model.authStatus = result["error"] as? String ?? OAuthFailure.storage.message }
                    }
                } message: { Text("保留论坛登录和当前草稿；增强页面会重新要求同账号绑定。") }
        }
    }
}

private struct PopupView: View {
    @ObservedObject var model: ShellModel
    let browser: WKWebView
    @State private var canGoBack = false
    @State private var confirmClose = false
    @State private var currentURL: URL?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: currentURL?.scheme == "https" ? "lock" : "globe")
                    Text(ShellPolicy.isForum(currentURL) ? "CC98 原站" : "网页地址").font(.caption)
                    Text(currentURL?.host ?? "等待网页地址").font(.subheadline.weight(.medium)).lineLimit(1)
                        .accessibilityIdentifier("popupHost")
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.vertical, 9).background(.bar)
                BrowserSurface(browser: browser)
            }
                .navigationTitle("网页窗口").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("返回论坛") { confirmClose = true } }
                    ToolbarItem(placement: .primaryAction) { Button("后退") { browser.goBack() }.disabled(!canGoBack) }
                }
        }.interactiveDismissDisabled(true)
            .onReceive(browser.publisher(for: \.canGoBack)) { canGoBack = $0 }
            .onReceive(browser.publisher(for: \.url)) { currentURL = $0 }
            .alert("关闭新窗口？", isPresented: $confirmClose) {
                Button("取消", role: .cancel) {}
                Button("关闭", role: .destructive) { model.closePopup() }
            } message: { Text("新窗口中未保存的编辑内容可能丢失；主页面会保留。") }
    }
}

private struct SafariSurface: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct ShareSurface: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
