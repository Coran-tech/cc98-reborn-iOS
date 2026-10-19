import SwiftUI

// Native "我的" destination for the validation shell. It follows
// MOBILE_UI_SPEC.md sections 14-16: one account/binding state, an explicit
// mode switch, honest status text and a separate about/boundary section.
struct MyView: View {
    @ObservedObject var model: ShellModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingAlert: MyAlert?

    private enum MyAlert: Identifiable {
        case unbind
        case mode(ShellMode)

        var id: String {
            switch self {
            case .unbind: return "unbind"
            case .mode(let mode): return "mode-" + mode.rawValue
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                modeSection
                statusSection
                downloadsSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ShellTheme.pageBackground)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .tint(ShellTheme.accent)
                }
            }
            .alert(item: $pendingAlert) { alert in alertContent(alert) }
            .onAppear { model.refreshWebAccountIfNeeded() }
        }
    }

    @MainActor
    private var accountSection: some View {
        Section {
            LabeledContent("网页账号") {
                Text(accountSummary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("OpenID 绑定") {
                Text(bindingSummary)
                    .multilineTextAlignment(.trailing)
            }
            if model.webAccount == .unavailable {
                Text("暂时无法确认当前网页账号；请确认已在原站登录，再重新核对。")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
            Button("核对当前网页账号") { model.refreshWebAccount() }
                .disabled(model.mode != .enhanced || model.isUITesting)
            Button(model.authBound ? "重新验证绑定" : "绑定当前网页账号") { model.retryBinding() }
                .disabled(model.mode != .enhanced || model.isUITesting || model.authBusy)
            Button("解除本机绑定", role: .destructive) { pendingAlert = .unbind }
                .disabled(!model.authBound)
        } header: {
            Text("账号与绑定")
        } footer: {
            Text("解除本机绑定不会退出论坛账号，也不会撤销站方授权；论坛登录始终在官方页面完成。")
        }
    }

    @MainActor
    private var modeSection: some View {
        Section {
            Button {
                if model.mode != .original { pendingAlert = .mode(.original) }
            } label: {
                modeRow("原站模式", "不注入 Reborn。用于登录、编辑、上传与故障恢复。", selected: model.mode == .original)
            }
            .buttonStyle(.plain)
            Button {
                if model.mode != .enhanced { pendingAlert = .mode(.enhanced) }
            } label: {
                modeRow("Reborn 验证", "从包内注入增强脚本与样式，按原站业务提交。", selected: model.mode == .enhanced)
            }
            .buttonStyle(.plain)
        } header: {
            Text("阅读模式")
        } footer: {
            Text("切换会新建网页并重新加载当前地址，未提交内容可能丢失；论坛登录数据保留。")
        }
    }

    @MainActor
    private var statusSection: some View {
        Section {
            LabeledContent("模式", value: model.mode.title)
            LabeledContent("当前地址", value: model.host)
            Text(model.status)
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
            Text(model.runtimeState)
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
            if let issue = model.assetIssue {
                Text(issue).font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.warning)
            }
            if let issue = model.settingsIssue {
                Text(issue).font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.warning)
            }
            Text(model.authStatus)
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
                .accessibilityIdentifier("authStatus")
        } header: {
            Text("当前状态")
        } footer: {
            Text("完整脱敏诊断记录在右上角的信息按钮中。")
        }
    }

    @MainActor
    @ViewBuilder
    private var downloadsSection: some View {
        if !model.completedDownloads.isEmpty {
            Section("本次下载（临时文件）") {
                ForEach(model.completedDownloads, id: \.self) { file in
                    ShareLink(item: file) {
                        Label(file.lastPathComponent, systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    @MainActor
    private var aboutSection: some View {
        Section {
            LabeledContent("App 版本", value: appVersion)
            LabeledContent("本地 Reborn", value: model.extensionVersion)
            Text("非官方开发验证壳。页面已加载、脚本已安排或收到报告，都不代表登录、绑定、编辑或上传通过。")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
            Text("诊断仅保存事件与状态码，不记录网址路径、查询参数、账号、正文、令牌或原始异常。")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
        } header: {
            Text("关于")
        }
    }

    @MainActor
    private var accountSummary: String {
        switch model.webAccount {
        case .unknown: return "尚未核对"
        case .checking: return "正在核对…"
        case .unavailable: return "暂时无法确认"
        case .signedIn(let id): return "UID \(id)"
        }
    }

    @MainActor
    private var bindingSummary: String {
        guard let binding = model.settings?.binding else { return "未绑定" }
        if case .signedIn(let id) = model.webAccount {
            return binding.userID == id ? "已绑定当前账号" : "绑定的是另一账号（UID \(binding.userID)）"
        }
        return "已绑定 UID \(binding.userID)"
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func modeRow(_ title: String, _ detail: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ShellTheme.Fonts.body)
                    .foregroundStyle(ShellTheme.primaryText)
                Text(detail)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(ShellTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    @MainActor
    private func alertContent(_ item: MyAlert) -> Alert {
        switch item {
        case .unbind:
            return Alert(
                title: Text("解除本机绑定？"),
                message: Text("保留论坛登录和当前草稿；增强页面会重新要求同账号绑定。"),
                primaryButton: .destructive(Text("解除")) {
                    let result = model.oauth.logout()
                    if result["ok"] as? Bool != true {
                        model.authStatus = result["error"] as? String ?? OAuthFailure.storage.message
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .mode(let mode):
            return Alert(
                title: Text("切换到\(mode.title)"),
                message: Text(ShellAction.mode(mode).detail),
                primaryButton: .destructive(Text("继续")) { model.switchMode(mode) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }
}
