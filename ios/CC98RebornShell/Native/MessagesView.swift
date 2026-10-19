import SwiftUI

struct MessagesView: View {
    @EnvironmentObject private var auth: NativeAuth

    var body: some View {
        NavigationStack {
            Group {
                if let user = auth.profile {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                NativeAvatar(url: user.avatarURL, name: user.name, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.name ?? "当前账号")
                                        .font(ShellTheme.Fonts.body.weight(.medium))
                                    Text("已登录")
                                        .font(ShellTheme.Fonts.caption)
                                        .foregroundStyle(ShellTheme.secondaryText)
                                }
                            }
                        }
                        Section("消息中心") {
                            Text("原生消息页正在接入。当前版本先提供浏览、版面与读帖；消息分类、私信和通知会在后续阶段补齐。")
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(ShellTheme.secondaryText)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(ShellTheme.pageBackground)
                } else {
                    LoginGateView()
                }
            }
            .navigationTitle("消息")
        }
    }
}
