import SwiftUI

enum NativeFollowKind: String, Identifiable {
    case followings
    case fans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followings: return "我的关注"
        case .fans: return "我的粉丝"
        }
    }

    var emptyTitle: String {
        switch self {
        case .followings: return "还没有关注任何人"
        case .fans: return "还没有粉丝"
        }
    }
}

struct FollowListView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary

    let kind: NativeFollowKind

    @State private var ids: [Int] = []
    @State private var users: [Int: NativeBasicUser] = [:]
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = true

    private let pageSize = 10

    var body: some View {
        Group {
            if auth.profile == nil {
                LoginGateView()
            } else if ids.isEmpty && loading {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if ids.isEmpty, let error {
                NativeStateView(icon: "person.2", title: "无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if ids.isEmpty {
                NativeStateView(icon: "person.2", title: kind.emptyTitle, message: nil)
            } else {
                List {
                    ForEach(ids, id: \.self) { id in
                        NavigationLink {
                            UserProfileView(userID: id, userName: users[id]?.name)
                        } label: {
                            HStack(spacing: 10) {
                                NativeAvatar(
                                    url: avatarURL(users[id]?.portraitUrl) ?? NativeAvatarURLs.defaultURL(gender: nil),
                                    name: users[id]?.name,
                                    size: 40
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(users[id]?.name ?? "用户 #\(id)")
                                        .font(ShellTheme.Fonts.body)
                                        .foregroundStyle(ShellTheme.primaryText)
                                    if !library.userNote(for: id).isEmpty {
                                        Text("备注：\(library.userNote(for: id))")
                                            .font(ShellTheme.Fonts.footnote)
                                            .foregroundStyle(ShellTheme.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if hasMore {
                        Button {
                            Task { await load(reset: false) }
                        } label: {
                            HStack {
                                Spacer()
                                if loading { ProgressView() }
                                Text(loading ? "正在加载…" : "加载更多")
                                Spacer()
                            }
                        }
                        .disabled(loading)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ShellTheme.pageBackground)
                .refreshable { await load(reset: true) }
            }
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(reset: true) }
    }

    private func avatarURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://www.cc98.org" + (raw.hasPrefix("/") ? raw : "/" + raw))
    }

    @MainActor
    private func load(reset: Bool) async {
        guard auth.profile != nil, !loading else { return }
        loading = true
        error = nil
        if reset {
            page = 0
            hasMore = true
        }
        do {
            let fetched: [Int]
            switch kind {
            case .followings:
                fetched = try await app.api.followings(from: page * pageSize, size: pageSize)
            case .fans:
                fetched = try await app.api.fans(from: page * pageSize, size: pageSize)
            }
            if reset {
                ids = fetched
            } else {
                let existing = Set(ids)
                ids.append(contentsOf: fetched.filter { !existing.contains($0) })
            }
            page += 1
            hasMore = fetched.count == pageSize

            let missing = fetched.filter { users[$0] == nil }
            if !missing.isEmpty, let basics = try? await app.api.userBasics(ids: missing) {
                var map = users
                for user in basics { map[user.id] = user }
                users = map
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
