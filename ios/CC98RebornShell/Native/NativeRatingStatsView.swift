import SwiftUI

struct RatingRecordTable: View {
    let awards: [NativeAward]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text("评分记录")
                    .font(ShellTheme.Fonts.footnote.weight(.semibold))
                    .foregroundStyle(ShellTheme.primaryText)
                Text(formatDelta(reputationDelta))
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(deltaColor)
                Text("所列风评合计")
                    .font(ShellTheme.Fonts.metadata)
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            ForEach(awards.indices, id: \.self) { index in
                let award = awards[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text(award.operatorName ?? "匿名")
                        .font(ShellTheme.Fonts.metadata.weight(.medium))
                        .foregroundStyle(ShellTheme.primaryText)
                    Text(award.content ?? "—")
                        .font(ShellTheme.Fonts.metadata.weight(.semibold))
                        .foregroundStyle(contentColor(award.content))
                    if let reason = award.reason, !reason.isEmpty {
                        Text(reason).font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                if index < awards.count - 1 { Divider() }
            }
        }
        .padding(10)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
    }

    private var reputationDelta: Int? {
        let values = awards.compactMap { NativeReputation.delta(in: $0.content) }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var deltaColor: Color {
        guard let reputationDelta else { return ShellTheme.secondaryText }
        if reputationDelta > 0 { return ShellTheme.accent }
        if reputationDelta < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func contentColor(_ content: String?) -> Color {
        guard let value = NativeReputation.delta(in: content) else {
            return ShellTheme.secondaryText
        }
        if value > 0 { return ShellTheme.accent }
        if value < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func formatDelta(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value > 0 ? "+\(value)" : String(value)
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
                                    Text("所列风评合计")
                                        .font(ShellTheme.Fonts.metadata)
                                        .foregroundStyle(ShellTheme.secondaryText)
                                }
                            }
                            Text("共 \(awards.count) 条")
                                .font(ShellTheme.Fonts.metadata)
                                .foregroundStyle(ShellTheme.secondaryText)
                        }

                        Section("评分记录") {
                            ForEach(awards.indices, id: \.self) { index in
                                let award = awards[index]
                                VStack(alignment: .leading, spacing: 4) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(award.operatorName ?? "匿名")
                                            .font(ShellTheme.Fonts.footnote.weight(.medium))
                                            .foregroundStyle(ShellTheme.primaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(award.content ?? "-")
                                            .font(ShellTheme.Fonts.footnote.weight(.semibold))
                                            .foregroundStyle(contentColor(award.content))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(NativeFormat.date(award.time))
                                            .font(ShellTheme.Fonts.metadata)
                                            .foregroundStyle(ShellTheme.secondaryText)
                                    }
                                    if let reason = award.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(ShellTheme.Fonts.metadata)
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
    private var reputationDelta: Int? {
        let values = awards.compactMap { NativeReputation.delta(in: $0.content) }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var deltaColor: Color {
        guard let reputationDelta else { return ShellTheme.secondaryText }
        if reputationDelta > 0 { return ShellTheme.accent }
        if reputationDelta < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func contentColor(_ content: String?) -> Color {
        guard let value = NativeReputation.delta(in: content) else {
            return ShellTheme.secondaryText
        }
        if value > 0 { return ShellTheme.accent }
        if value < 0 { return ShellTheme.danger }
        return ShellTheme.secondaryText
    }

    private func formatDelta(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value > 0 ? "+\(value)" : String(value)
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
