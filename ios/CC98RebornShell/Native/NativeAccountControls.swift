import SwiftUI

// Shared by the profile and the logged-out recovery gate, so saved accounts
// remain reachable even when /me cannot currently be loaded.
struct NativeAccountControls: View {
    // The login gate presents one state-specific primary action above this list.
    var showsSessionActions = true
    @EnvironmentObject private var auth: NativeAuth
    @State private var error: String?
    @State private var confirmSignOut = false
    @State private var accountToRemove: NativeAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsSessionActions, case let .unavailable(message) = auth.state {
                Text(message).foregroundStyle(ShellTheme.secondaryText)
                Button("恢复已保存登录") { Task { await auth.restore() } }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("account.restore")
            } else if showsSessionActions, case let .requiresAuthorization(message) = auth.state {
                Text(message).foregroundStyle(ShellTheme.secondaryText)
            } else if showsSessionActions, auth.profile != nil {
                Text(auth.hasRefreshAuthorization
                     ? "已记住此账号，将在授权有效期内自动续期。"
                     : "当前会话尚未取得刷新授权，可重新授权以启用长期登录。")
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            if showsSessionActions, let id = auth.activeAccountID,
               let title = auth.state.longSessionAuthorizationTitle(hasRefreshAuthorization: auth.hasRefreshAuthorization) {
                Button(title) {
                    perform { try await auth.reauthorize(accountID: id) }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("account.reauthorize")
            }

            ForEach(auth.accounts) { account in
                HStack(spacing: 10) {
                    Button {
                        perform { try await auth.switchAccount(to: account.id) }
                    } label: {
                        HStack(spacing: 10) {
                            NativeAvatar(url: URL(string: account.avatarURL ?? ""), name: account.name, size: 30)
                            Text(account.name).foregroundStyle(ShellTheme.primaryText)
                            Spacer(minLength: 0)
                            if account.id == auth.activeAccountID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(ShellTheme.accent)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button("重新授权") { perform { try await auth.reauthorize(accountID: account.id) } }
                        Button("重新输入账号") {
                            perform { try await auth.reauthorize(accountID: account.id, forceEphemeral: true) }
                        }
                        .accessibilityHint("使用独立登录窗口，仍须登录 \(account.name)，不会切换到其他账号")
                        .accessibilityIdentifier("account.reenter.\(account.id)")
                        if account.id != auth.activeAccountID {
                            Button("移除本机账号", role: .destructive) {
                                accountToRemove = account
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(account.name) 的账号操作")
                }
            }

            Button { perform { try await auth.addAccount() } } label: {
                Label("添加账号", systemImage: "person.badge.plus").frame(minHeight: 44)
            }
            .accessibilityIdentifier("account.add")
            if auth.profile == nil, auth.activeAccountID != nil {
                Button("退出当前账号", role: .destructive) { confirmSignOut = true }
                    .frame(minHeight: 44)
            }
            if auth.isBusy { ProgressView("正在处理账号…") }
            if let error { Text(error).foregroundStyle(ShellTheme.danger) }
        }
        .font(ShellTheme.Fonts.footnote)
        .disabled(auth.isBusy)
        .alert("退出当前账号？", isPresented: $confirmSignOut) {
            Button("取消", role: .cancel) { }
            Button("退出", role: .destructive) { Task { await auth.signOutCurrent() } }
        } message: {
            Text("将移除此账号的本机登录，并尝试切换到下一个已保存账号。草稿与历史不会删除。")
        }
        .alert("移除本机账号？", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        ), presenting: accountToRemove) { account in
            Button("取消", role: .cancel) { }
            Button("移除", role: .destructive) { Task { await auth.removeAccount(account.id) } }
        } message: { account in
            Text("仅移除 \(account.name) 的本机登录凭据，不删除该账号的草稿、备注和历史，也不撤销站方授权。")
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { @MainActor in
            do { try await operation() }
            catch NativeAuthError.cancelled { }
            catch { self.error = error.localizedDescription }
        }
    }
}
