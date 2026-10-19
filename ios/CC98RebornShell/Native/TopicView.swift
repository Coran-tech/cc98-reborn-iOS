import SwiftUI

struct TopicDetailView: View {
    @EnvironmentObject private var app: NativeAppModel

    let topicID: Int
    let boardID: Int?

    @State private var topic: NativeTopic?
    @State private var posts: [NativePost] = []
    @State private var page = 1
    @State private var loading = false
    @State private var error: String?

    private let pageSize = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let topic { header(topic) }

                if posts.isEmpty && loading {
                    ProgressView("正在加载楼层…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if posts.isEmpty, let error {
                    NativeStateView(icon: "exclamationmark.bubble", title: "主题无法加载", message: error, action: {
                        Task { await load() }
                    })
                    .frame(minHeight: 280)
                } else {
                    ForEach(posts) { post in
                        PostCard(post: post)
                    }
                    if let error {
                        Text(error)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if pageCount > 1 { pager }
                }
            }
            .padding(16)
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: page) { await load() }
    }

    private var pageCount: Int {
        let total = (topic?.replyCount ?? 0) + 1
        return max(1, (total + pageSize - 1) / pageSize)
    }

    private func header(_ topic: NativeTopic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title ?? "主题 #\(topic.id)")
                .font(ShellTheme.Fonts.pageTitle)
                .foregroundStyle(ShellTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"))
                Text(NativeFormat.date(topic.time))
                Spacer(minLength: 0)
                Text("回复 \(NativeFormat.count(topic.replyCount))")
                Text("点击 \(NativeFormat.count(topic.hitCount))")
            }
            .font(ShellTheme.Fonts.caption)
            .foregroundStyle(ShellTheme.secondaryText)
            if let boardID {
                Text("版面 #\(boardID)")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
    }

    private var pager: some View {
        HStack {
            Button("上一页") {
                if page > 1 { page -= 1 }
            }
            .disabled(page <= 1 || loading)
            Spacer()
            Text("第 \(page) / \(pageCount) 页")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
            Spacer()
            Button("下一页") {
                if page < pageCount { page += 1 }
            }
            .disabled(page >= pageCount || loading)
        }
        .buttonStyle(.bordered)
        .tint(ShellTheme.accent)
        .padding(.vertical, 8)
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            async let topicRequest = app.api.topic(id: topicID)
            async let postsRequest = app.api.posts(topicID: topicID, from: (page - 1) * pageSize, size: pageSize)
            let loadedTopic = try await topicRequest
            let loadedPosts = try await postsRequest
            topic = loadedTopic
            posts = loadedPosts
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct PostCard: View {
    let post: NativePost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                NativeAvatar(url: nil, name: post.userName, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(post.isAnonymous == true ? "匿名" : (post.userName ?? "未知作者"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ShellTheme.primaryText)
                        if post.isLZ == true { badge("楼主", color: ShellTheme.accent) }
                        if post.isBest == true { badge("精彩", color: ShellTheme.warning) }
                    }
                    Text("\(floorTitle) · \(NativeFormat.date(post.time))")
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }

            if let content = post.content, !content.isEmpty {
                UBBText(source: content, markdown: post.contentType == 1)
                    .textSelection(.enabled)
            } else {
                Text("（内容为空）")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            if post.isDeleted == true {
                Text("该楼层已被删除")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.danger)
            }

            HStack(spacing: 14) {
                Label(NativeFormat.count(post.likeCount), systemImage: "hand.thumbsup")
                Label(NativeFormat.count(post.dislikeCount), systemImage: "hand.thumbsdown")
                Spacer(minLength: 0)
            }
            .font(ShellTheme.Fonts.caption)
            .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
    }

    private var floorTitle: String {
        guard let floor = post.floor, floor > 0 else { return "首楼" }
        return "\(floor) 楼"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct UBBText: View {
    let source: String
    var markdown: Bool = false

    var body: some View {
        Text(attributed)
            .font(ShellTheme.Fonts.body)
            .foregroundStyle(ShellTheme.primaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        let text = String(source.prefix(200_000))
        if markdown, let value = try? AttributedString(markdown: text) {
            return value
        }
        var parser = UBBParser()
        return parser.parse(text)
    }
}

private struct UBBParser {
    private var bold = 0
    private var italic = 0
    private var underline = 0
    private var code = 0
    private var link: URL?
    private var color: Color?
    private var imageBuffer: String?

    mutating func parse(_ source: String) -> AttributedString {
        let normalized = sanitize(source)
        var result = AttributedString()
        guard let regex = try? NSRegularExpression(
            pattern: "\\[\\s*(/)?\\s*([a-zA-Z][a-zA-Z0-9]*)(?:\\s*=\\s*([^\\]]*))?\\s*\\]",
            options: []
        ) else {
            append(normalized, to: &result)
            return result
        }
        let ns = normalized as NSString
        let matches = regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &result)
            }
            let closing = match.range(at: 1).location != NSNotFound
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            let value = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : nil
            handle(name: name, closing: closing, value: value, result: &result)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            append(ns.substring(from: cursor), to: &result)
        }
        return result
    }

    private mutating func handle(name: String, closing: Bool, value: String?, result: inout AttributedString) {
        switch name {
        case "b": bold = max(0, bold + (closing ? -1 : 1))
        case "i": italic = max(0, italic + (closing ? -1 : 1))
        case "u": underline = max(0, underline + (closing ? -1 : 1))
        case "code": code = max(0, code + (closing ? -1 : 1))
        case "url":
            if closing {
                link = nil
            } else if let value {
                link = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "img":
            if closing {
                if let buffer = imageBuffer {
                    appendImage(buffer, to: &result)
                }
                imageBuffer = nil
            } else {
                imageBuffer = ""
            }
        case "quote":
            append(closing ? "\n" : "「引用」\n", to: &result)
        case "color":
            if closing {
                color = nil
            } else if let value {
                color = Color(ubbHex: value)
            }
        case "hr":
            append("\n———\n", to: &result)
        case "br":
            append("\n", to: &result)
        default:
            if name.hasPrefix("ac"), name.count > 2, name.dropFirst(2).allSatisfy({ $0.isNumber }) {
                append("🙂", to: &result)
            }
        }
    }

    private mutating func append(_ raw: String, to result: inout AttributedString) {
        let text = decodeEntities(raw)
        guard !text.isEmpty else { return }
        if imageBuffer != nil {
            imageBuffer?.append(text)
            return
        }
        var container = AttributeContainer()
        var font = Font.body
        if bold > 0 { font = font.bold() }
        if italic > 0 { font = font.italic() }
        if code > 0 { font = .system(.body, design: .monospaced) }
        if bold > 0 || italic > 0 || code > 0 { container.font = font }
        if underline > 0 { container.underlineStyle = Text.LineStyle.single }
        if let link { container.link = link }
        if let color { container.foregroundColor = color }
        var run = AttributedString(text)
        run.setAttributes(container)
        result.append(run)
    }

    private mutating func appendImage(_ raw: String, to result: inout AttributedString) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var container = AttributeContainer()
        container.foregroundColor = ShellTheme.link
        if let url = URL(string: trimmed) { container.link = url }
        var run = AttributedString("［图片］")
        run.setAttributes(container)
        result.append(run)
    }

    private func sanitize(_ source: String) -> String {
        var value = source
        value = value.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return value
    }

    private func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

private extension Color {
    init?(ubbHex raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 3, let number = UInt32(value, radix: 16) else { return nil }
        let red: UInt32
        let green: UInt32
        let blue: UInt32
        if value.count == 6 {
            red = (number >> 16) & 0xFF
            green = (number >> 8) & 0xFF
            blue = number & 0xFF
        } else {
            let r = (number >> 8) & 0xF
            let g = (number >> 4) & 0xF
            let b = number & 0xF
            red = r * 17; green = g * 17; blue = b * 17
        }
        self.init(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }
}
