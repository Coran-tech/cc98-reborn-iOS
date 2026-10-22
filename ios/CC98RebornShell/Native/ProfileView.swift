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

    var body: some View {
        NavigationStack {
            Group {
                if let user = auth.profile {
                    profileList(user)
                } else {
                    LoginGateView()
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
            Text("将移除此账号的本机登录，并尝试切换到下一个已保存账号。草稿与历史不会删除。")
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

            Section("账号与登录") {
                NativeAccountControls()
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
