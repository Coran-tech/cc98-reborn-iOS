import SwiftUI

struct SearchSnippetText: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        composed
            .fixedSize(horizontal: false, vertical: true)
    }

    private var composed: Text {
        guard let regex = try? NSRegularExpression(
            pattern: "\\[(cc98\\d{2}|ac\\d{2,4}|em\\d{2}|ms\\d{2}|tb\\d{2})\\]",
            options: .caseInsensitive
        ) else {
            return Text(text)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Text(text) }

        var result = Text("")
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result = result + Text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let tag = ns.substring(with: match.range(at: 1)).lowercased()
            if let image = UBBEmotion.image(tag, light: colorScheme == .dark, maxSide: 18) {
                result = result + Text(Image(uiImage: image))
            } else {
                result = result + Text(ns.substring(with: match.range))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result = result + Text(ns.substring(from: cursor))
        }
        return result
    }
}

struct TopicFullTextSearchView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss

    let topicID: Int
    let maxPage: Int
    let onJump: (Int) -> Void

    @State private var query = ""
    @State private var includeQuotes = true
    @State private var hits: [Hit] = []
    @State private var searching = false
    @State private var progress = 0
    @State private var error: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    private let pageSize = 10

    private struct Hit: Identifiable {
        let id: Int
        let floor: Int
        let userName: String?
        let snippet: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(ShellTheme.secondaryText)
                        TextField("正文、用户名、UID 或 [ac01]", text: $query)
                            .submitLabel(.search)
                            .onSubmit { startSearch() }
                        Button("搜索") { startSearch() }
                            .font(ShellTheme.Fonts.footnote.weight(.medium))
                            .foregroundStyle(ShellTheme.accent)
                            .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Toggle("包含引用内容", isOn: $includeQuotes)
                        .font(ShellTheme.Fonts.footnote)
                }
                .padding(16)
                .background(ShellTheme.surface)

                if searching {
                    ProgressView(value: Double(progress), total: Double(max(1, maxPage))) {
                        Text("正在搜索 \(progress) / \(maxPage) 页")
                            .font(ShellTheme.Fonts.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                if let error {
                    NativeStateView(icon: "magnifyingglass", title: "搜索中断", message: error)
                } else if hits.isEmpty {
                    NativeStateView(
                        icon: "text.magnifyingglass",
                        title: searching ? "正在搜索" : "帖内全文搜索",
                        message: searching ? "命中结果会陆续显示。" : "搜索本帖所有楼层。"
                    )
                } else {
                    List {
                        Section("找到 \(hits.count) 个楼层") {
                            ForEach(hits) { hit in
                                Button {
                                    onJump(hit.floor)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text("#\(hit.floor) · \(hit.userName ?? "CC98 用户")")
                                                .font(ShellTheme.Fonts.footnote.weight(.medium))
                                                .foregroundStyle(ShellTheme.primaryText)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(ShellTheme.secondaryText)
                                        }
                                        SearchSnippetText(text: hit.snippet)
                                            .font(ShellTheme.Fonts.caption)
                                            .foregroundStyle(ShellTheme.secondaryText)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("全文搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        searchTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private func startSearch() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !searching else { return }
        searchTask?.cancel()
        hits = []
        error = nil
        progress = 0
        searching = true
        searchTask = Task { await search(keyword) }
    }

    @MainActor
    private func search(_ keyword: String) async {
        do {
            for page in 1...max(1, maxPage) {
                try Task.checkCancellation()
                let posts = try await app.api.posts(
                    topicID: topicID,
                    from: (page - 1) * pageSize,
                    size: pageSize
                )
                try Task.checkCancellation()
                for post in posts {
                    if let hit = match(post: post, keyword: keyword) {
                        hits.append(hit)
                    }
                }
                progress = page
            }
        } catch is CancellationError {
            searching = false
            return
        } catch {
            self.error = error.localizedDescription
        }
        searching = false
    }

    private func match(post: NativePost, keyword: String) -> Hit? {
        var source = post.content ?? ""
        if !includeQuotes {
            source = source.replacingOccurrences(
                of: "(?is)\\[quote\\].*?\\[/quote\\]",
                with: " ",
                options: .regularExpression
            )
        }
        let plain = UBBBlockParser.searchableText(source)
        let author = [post.userName, post.userId.map { "UID \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let haystack = [source, plain, author].joined(separator: " ").lowercased()
        guard haystack.contains(keyword.lowercased()) else { return nil }

        let lower = plain.lowercased()
        let needle = keyword.lowercased()
        let range = lower.range(of: needle)
        let snippet: String
        if let range {
            let start = plain.index(range.lowerBound, offsetBy: -45, limitedBy: plain.startIndex) ?? plain.startIndex
            let end = plain.index(range.upperBound, offsetBy: 100, limitedBy: plain.endIndex) ?? plain.endIndex
            snippet = String(plain[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            snippet = String(plain.prefix(140))
        }
        return Hit(
            id: post.id,
            floor: post.floor ?? 1,
            userName: post.userName,
            snippet: snippet.isEmpty ? (post.content ?? "") : snippet
        )
    }
}
