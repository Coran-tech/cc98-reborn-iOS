import SwiftUI

struct RatingRecordTable: View {
    let awards: [NativeAward]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("评分记录")
                    .font(ShellTheme.Fonts.footnote.weight(.semibold))
                    .foregroundStyle(ShellTheme.primaryText)
                Spacer(minLength: 0)
                Text(formatDelta(reputationDelta))
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(deltaColor)
                Text("风评合计")
                    .font(.system(size: 10))
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("用户")
                    Text("操作")
                    Text("理由")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ShellTheme.secondaryText)

                ForEach(awards.indices, id: \.self) { index in
                    let award = awards[index]
                    GridRow {
                        Text(award.operatorName ?? "匿名")
                            .font(.system(size: 11))
                            .foregroundStyle(ShellTheme.primaryText)
                            .lineLimit(1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(award.content ?? "-")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(contentColor(award.content))
                            if !isReputation(award.content) {
                                Text("不计入风评")
                                    .font(.system(size: 9))
                                    .foregroundStyle(ShellTheme.secondaryText)
                            }
                        }
                        Text(award.reason ?? "-")
                            .font(.system(size: 11))
                            .foregroundStyle(ShellTheme.secondaryText)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(10)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
    }

    private var reputationDelta: Int {
        awards.filter { isReputation($0.content) }
            .compactMap { signedNumber(in: $0.content ?? "") }
            .reduce(0, +)
    }

    private func isReputation(_ content: String?) -> Bool {
        guard let content else { return false }
        if content.contains("风评值") { return true }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^[+-]?\\d+$", options: .regularExpression) != nil
    }

    private var deltaColor: Color {
        if reputationDelta > 0 { return ShellTheme.accent }
        if reputationDelta < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func contentColor(_ content: String?) -> Color {
        guard isReputation(content), let value = signedNumber(in: content ?? "") else {
            return ShellTheme.secondaryText
        }
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
}

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

    // Only operations that describe 风评值 (or a bare signed value) count
    // toward the total. Wealth/prestige changes remain visible but neutral.
    private var reputationDelta: Int {
        awards.filter { isReputation($0.content) }
            .compactMap { signedNumber(in: $0.content ?? "") }
            .reduce(0, +)
    }

    private func isReputation(_ content: String?) -> Bool {
        guard let content else { return false }
        if content.contains("风评值") { return true }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^[+-]?\\d+$", options: .regularExpression) != nil
    }

    private var deltaColor: Color {
        if reputationDelta > 0 { return ShellTheme.accent }
        if reputationDelta < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func contentColor(_ content: String?) -> Color {
        guard isReputation(content), let value = signedNumber(in: content ?? "") else {
            return ShellTheme.secondaryText
        }
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
