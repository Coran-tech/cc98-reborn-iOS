import SwiftUI

struct ProfileView: View {
    private enum ProfileDestination: String, Identifiable {
        case activity
        case followings
        case fans

        var id: String { rawValue }
    }

    @EnvironmentObject private var auth: NativeAuth
    @State private var confirmSignOut = false
    @State private var destination: ProfileDestination?
    @State private var switchingAccountID: Int?
    @State private var accountError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let user = auth.profile {
                    profileList(user)
                } else {
                    VStack(spacing: 0) {
                        LoginGateView()
                        if case let .unavailable(message) = auth.state {
                            Text(message)
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(ShellTheme.danger)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 24)
                        }
                    }
                    .background(ShellTheme.pageBackground)
                }
            }
            .navigationTitle("我的")
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .activity:
                    MyActivityView()
                case .followings:
                    FollowListView(kind: .followings)
                case .fans:
                    FollowListView(kind: .fans)
                }
            }
        }
        .alert("退出当前账号？", isPresented: $confirmSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                Task { await auth.signOutCurrent() }
            }
        } message: {
            Text("退出当前账号？其他已保存账号会保留。")
        }
        .alert("账号切换失败", isPresented: Binding(
            get: { accountError != nil },
            set: { if !$0 { accountError = nil } }
        )) {
            Button("好", role: .cancel) { accountError = nil }
        } message: {
            Text(accountError ?? "")
        }
    }

    private func profileList(_ user: NativeUser) -> some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    NativeAvatar(url: user.avatarURL ?? NativeAvatarURLs.defaultURL(gender: user.gender), name: user.name, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name ?? "CC98 用户")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(ShellTheme.primaryText)
                        let title = user.customTitle ?? user.displayTitle
                        if let title, !title.isEmpty {
                            Text(title)
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(ShellTheme.secondaryText)
                        }
                        if let introduction = user.introduction, !introduction.isEmpty {
                            Text(introduction)
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(ShellTheme.secondaryText)
                                .lineLimit(3)
                                .padding(.top, 1)
                        }
                    }
                }
                .padding(.vertical, 4)

                HStack(spacing: 8) {
                    statButton("发帖", NativeFormat.count(user.postCount), destination: .activity)
                    statDivider
                    profileStat("威望", NativeFormat.count(user.prestige))
                    statDivider
                    profileStat("风评", NativeFormat.count(user.popularity))
                    statDivider
                    statButton("关注", NativeFormat.count(user.followCount), destination: .followings)
                    statDivider
                    statButton("粉丝", NativeFormat.count(user.fanCount), destination: .fans)
                }
            }

            Section("账号切换") {
                ForEach(auth.accounts) { account in
                    Button {
                        guard account.id != auth.activeAccountID else { return }
                        switchingAccountID = account.id
                        Task {
                            do {
                                try await auth.switchAccount(to: account.id)
                            } catch {
                                accountError = error.localizedDescription
                            }
                            switchingAccountID = nil
                        }
                    } label: {
                        HStack(spacing: 10) {
                            NativeAvatar(
                                url: URL(string: account.avatarURL ?? ""),
                                name: account.name,
                                size: 30
                            )
                            Text(account.name)
                                .foregroundStyle(ShellTheme.primaryText)
                            Spacer(minLength: 0)
                            if switchingAccountID == account.id {
                                ProgressView()
                            } else if account.id == auth.activeAccountID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ShellTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if account.id != auth.activeAccountID {
                            Button("移除账号", role: .destructive) {
                                Task { await auth.removeAccount(account.id) }
                            }
                        }
                    }
                }

                Button {
                    Task {
                        do {
                            try await auth.addAccount()
                        } catch {
                            accountError = error.localizedDescription
                        }
                    }
                } label: {
                    Label("添加账号", systemImage: "person.badge.plus")
                }
            }

            Section("我的内容") {
                NavigationLink("我的收藏") { FavoritesView() }
                NavigationLink("稍后再看") { ReadLaterView() }
                NavigationLink("浏览历史") { HistoryView() }
                NavigationLink("查看我的主页") { UserProfileView(userID: user.id, userName: user.name) }
                NavigationLink("编辑资料") { ProfileSettingsView() }
                NavigationLink("设置") { SettingsView() }
            }

            Section("资料") {
                LabeledContent("用户 ID", value: String(user.id))
                if let register = user.registerTime {
                    LabeledContent("注册时间", value: NativeFormat.date(register))
                }
                if let lastLogOn = user.lastLogOnTime {
                    LabeledContent("最后登录", value: NativeFormat.date(lastLogOn))
                }
            }

            Section {
                Button("退出当前账号", role: .destructive) { confirmSignOut = true }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ShellTheme.pageBackground)
    }

    private func statButton(_ title: String, _ value: String, destination route: ProfileDestination) -> some View {
        Button {
            destination = route
        } label: {
            profileStat(title, value)
        }
        .buttonStyle(.plain)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(ShellTheme.separator)
            .frame(width: 0.5, height: 28)
    }

    private func profileStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(ShellTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
