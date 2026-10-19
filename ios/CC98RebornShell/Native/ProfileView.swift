import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var auth: NativeAuth
    @State private var confirmSignOut = false

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
        }
        .alert("退出登录？", isPresented: $confirmSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { auth.signOut() }
        } message: {
            Text("退出后将从本机钥匙串删除登录令牌；不会影响 CC98 账号本身。")
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

                HStack(spacing: 10) {
                    profileStat("发帖", NativeFormat.count(user.postCount))
                    profileStat("威望", NativeFormat.count(user.prestige))
                    profileStat("风评", NativeFormat.count(user.popularity))
                    profileStat("关注", NativeFormat.count(user.followCount))
                    profileStat("粉丝", NativeFormat.count(user.fanCount))
                }
            }

            Section("社交") {
                NavigationLink {
                    FollowListView(kind: .followings)
                } label: {
                    socialRow("关注", count: user.followCount, systemImage: "person.badge.plus")
                }
                NavigationLink {
                    FollowListView(kind: .fans)
                } label: {
                    socialRow("粉丝", count: user.fanCount, systemImage: "person.2")
                }
            }

            Section("我的内容") {
                NavigationLink("回复 + 发帖") { MyActivityView() }
                NavigationLink("我的收藏") { FavoritesView() }
                NavigationLink("稍后再看") { ReadLaterView() }
                NavigationLink("浏览历史") { HistoryView() }
                NavigationLink("查看我的主页") { UserProfileView(userID: user.id, userName: user.name) }
                NavigationLink("编辑资料") { ProfileSettingsView() }
                NavigationLink("设置") { SettingsView() }
            }

            Section("账号") {
                LabeledContent("用户 ID", value: String(user.id))
                if let register = user.registerTime {
                    LabeledContent("注册时间", value: NativeFormat.date(register))
                }
                if let lastLogOn = user.lastLogOnTime {
                    LabeledContent("最后登录", value: NativeFormat.date(lastLogOn))
                }
            }

            Section {
                Button("退出登录", role: .destructive) { confirmSignOut = true }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                Text("原生客户端 · 数据来自 api.cc98.org，使用 CC98 OpenID 授权。")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                Text("访问令牌只保存在本机钥匙串；退出登录会删除令牌。界面跟随系统深浅色。")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ShellTheme.pageBackground)
    }

    private func socialRow(_ title: String, count: Int?, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 0)
            Text(NativeFormat.count(count))
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
        }
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
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
