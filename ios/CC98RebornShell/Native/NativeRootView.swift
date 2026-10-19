import SwiftUI

@MainActor
final class NativeAppModel: ObservableObject {
    let auth: NativeAuth
    let api: CC98API

    init() {
        let auth = NativeAuth()
        self.auth = auth
        self.api = CC98API(auth: auth)
    }
}

struct NativeRootView: View {
    @StateObject private var app = NativeAppModel()
    @StateObject private var library = NativeLibrary()
    @AppStorage("native.appearance") private var appearance = "system"

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("浏览", systemImage: "list.bullet.rectangle") }
            BoardsView()
                .tabItem { Label("版面", systemImage: "square.grid.2x2") }
            MessagesView()
                .tabItem { Label("消息", systemImage: "bubble.left.and.bubble.right") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(ShellTheme.accent)
        .environmentObject(app)
        .environmentObject(app.auth)
        .environmentObject(library)
        .preferredColorScheme(preferredColorScheme)
        .task { @MainActor in await app.auth.restore() }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct LoginGateView: View {
    @EnvironmentObject private var auth: NativeAuth
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 46))
                .foregroundStyle(ShellTheme.accent)
            Text("登录 CC98")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ShellTheme.primaryText)
            Text("使用 CC98 OpenID 授权。登录后可查看消息、收藏并参与回复；令牌只保存在本机钥匙串。")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "正在登录…" : "使用 CC98 登录")
                        .font(ShellTheme.Fonts.body.weight(.medium))
                }
                .frame(minWidth: 180, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(ShellTheme.accent)
            .disabled(busy)
            if let error {
                Text(error)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShellTheme.pageBackground)
    }

    @MainActor
    private func signIn() async {
        busy = true
        error = nil
        do {
            try await auth.signIn()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

enum NativeAvatarURLs {
    static let anonymousURL = URL(string: "https://www.cc98.org/static/images/%E5%BF%83%E7%81%B5%E5%A4%B4%E5%83%8F.gif")

    static func defaultURL(gender: Int?) -> URL? {
        let file = gender == 2 ? "default_avatar_girl.png" : "default_avatar_boy.png"
        return URL(string: "https://www.cc98.org/static/images/" + file)
    }

    static func resolved(url: URL?, gender: Int?, anonymous: Bool = false) -> URL? {
        if anonymous { return anonymousURL }
        return url ?? defaultURL(gender: gender)
    }
}

struct NativeAvatar: View {
    let url: URL?
    let name: String?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(ShellTheme.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            ShellTheme.accentSoft
            Text(initial)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(ShellTheme.accent)
        }
    }

    private var initial: String {
        String((name ?? "?").prefix(1)).uppercased()
    }
}

struct NativeStateView: View {
    let icon: String
    let title: String
    let message: String?
    var actionTitle: String = "重试"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(ShellTheme.secondaryText)
            Text(title)
                .font(ShellTheme.Fonts.navigationTitle)
                .foregroundStyle(ShellTheme.primaryText)
            if let message {
                Text(message)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(ShellTheme.accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShellTheme.pageBackground)
    }
}

enum NativeFormat {
    static func date(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var value = raw.replacingOccurrences(of: "T", with: " ")
        if let dot = value.firstIndex(of: ".") { value = String(value[..<dot]) }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        if let z = value.firstIndex(of: "Z") { value = String(value[..<z]) }
        return value.count > 16 ? String(value.prefix(16)) : value
    }

    static func dateValue(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value >= 10000 {
            return String(format: "%.1f万", Double(value) / 10000)
        }
        return String(value)
    }

    static func plainCount(_ value: Int?) -> String {
        guard let value else { return "—" }
        return String(value)
    }
}
