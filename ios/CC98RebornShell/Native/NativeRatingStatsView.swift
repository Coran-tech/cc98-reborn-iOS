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
                    ProgressView("正在加载风评…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if awards.isEmpty, let error {
                    NativeStateView(icon: "chart.bar", title: "风评无法加载", message: error, action: {
                        Task { await load() }
                    })
                } else if awards.isEmpty {
                    NativeStateView(icon: "chart.bar", title: "暂无风评记录", message: nil)
                } else {
                    List {
                        Section("统计") {
                            HStack(spacing: 10) {
                                stat("好评", positiveCount)
                                stat("差评", negativeCount)
                                stat("总计", awards.count)
                            }
                        }

                        if !reasonGroups.isEmpty {
                            Section("理由分布") {
                                ForEach(reasonGroups.indices, id: \.self) { index in
                                    reasonRow(reasonGroups[index])
                                }
                            }
                        }

                        Section("记录") {
                            ForEach(awards.indices, id: \.self) { index in
                                let award = awards[index]
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(award.operatorName ?? "匿名")
                                            .font(ShellTheme.Fonts.footnote.weight(.medium))
                                            .foregroundStyle(ShellTheme.primaryText)
                                        if let content = award.content, !content.isEmpty {
                                            Text(content)
                                                .font(ShellTheme.Fonts.caption)
                                                .foregroundStyle(ShellTheme.accent)
                                        }
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

    private var positiveCount: Int {
        awards.filter { $0.type == 1 }.count
    }

    private var negativeCount: Int {
        awards.filter { $0.type == 2 }.count
    }

    private var reasonGroups: [(String, Int)] {
        var counts: [String: Int] = [:]
        for award in awards {
            let key = (award.reason?.isEmpty == false ? award.reason : award.content) ?? "未注明"
            counts[key, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .map { ($0.key, $0.value) }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(String(value))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(ShellTheme.primaryText)
            Text(title)
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private func reasonRow(_ item: (String, Int)) -> some View {
        HStack {
            Text(item.0)
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.primaryText)
            Spacer(minLength: 0)
            Text("\(item.1)")
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
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
