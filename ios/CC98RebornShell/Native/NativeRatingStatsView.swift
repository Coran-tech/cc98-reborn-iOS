import SwiftUI

struct RatingStatsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss

    let postID: Int

    @State private var awards: [NativeAward] = []
    @State private var loading = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if loading && awards.isEmpty {
                    ProgressView("正在加载评分记录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if awards.isEmpty, let error {
                    NativeStateView(icon: "list.bullet.rectangle", title: "评分记录无法加载", message: error, action: {
                        Task { await load() }
                    })
                } else if awards.isEmpty {
                    NativeStateView(icon: "list.bullet.rectangle", title: "暂无评分记录", message: nil)
                } else {
                    List {
                        Section {
                            HStack(alignment: .firstTextBaseline) {
                                Text("评分记录")
                                    .font(ShellTheme.Fonts.body.weight(.medium))
                                    .foregroundStyle(ShellTheme.primaryText)
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatDelta(reputationDelta))
                                        .font(.system(.title3, design: .rounded).weight(.semibold))
                                        .foregroundStyle(deltaColor)
                                    Text("风评合计")
                                        .font(ShellTheme.Fonts.caption)
                                        .foregroundStyle(ShellTheme.secondaryText)
                                }
                            }
                            Text("共 \(awards.count) 条")
                                .font(ShellTheme.Fonts.caption)
                                .foregroundStyle(ShellTheme.secondaryText)
                        }

                        Section("评分记录") {
                            ForEach(awards.indices, id: \.self) { index in
                                let award = awards[index]
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(award.operatorName ?? "匿名")
                                            .font(ShellTheme.Fonts.footnote.weight(.medium))
                                            .foregroundStyle(ShellTheme.primaryText)
                                            .lineLimit(1)
                                        Text(award.content ?? "-")
                                            .font(ShellTheme.Fonts.footnote.weight(.semibold))
                                            .foregroundStyle(contentColor(award.content))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(NativeFormat.date(award.time))
                                            .font(ShellTheme.Fonts.caption)
                                            .foregroundStyle(ShellTheme.secondaryText)
                                    }
                                    if let reason = award.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(ShellTheme.Fonts.caption)
                                            .foregroundStyle(ShellTheme.secondaryText)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("风评统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    // The original table sums rows whose operation contains 风评值, e.g.
    // "风评值 +1" / "风评值 -1". If a server returns a bare signed value,
    // fall back to summing the operation field directly.
    private var reputationDelta: Int {
        let explicit = awards.compactMap { award -> Int? in
            guard let content = award.content, content.contains("风评值") else { return nil }
            return signedNumber(in: content)
        }
        if !explicit.isEmpty {
            return explicit.reduce(0, +)
        }
        return awards.compactMap { signedNumber(in: $0.content ?? "") }.reduce(0, +)
    }

    private var deltaColor: Color {
        if reputationDelta > 0 { return ShellTheme.accent }
        if reputationDelta < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func contentColor(_ content: String?) -> Color {
        guard let value = signedNumber(in: content ?? "") else { return ShellTheme.secondaryText }
        if value > 0 { return ShellTheme.accent }
        if value < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func signedNumber(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "([+-]?\\d+)") else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    private func formatDelta(_ value: Int) -> String {
        value > 0 ? "+\(value)" : String(value)
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            awards = try await app.api.postAwards(postID: postID)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
