import SwiftUI
import Foundation

struct NativeVoteCard: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    let topicID: Int
    let info: NativeVoteInfo
    var onVoted: () -> Void

    @State private var selected: Set<Int> = []
    @State private var submitting = false
    @State private var errorMessage: String? = nil

    private var items: [NativeVoteItem] { info.voteItems ?? [] }
    private var myItems: Set<Int> { Set(info.myRecord?.items ?? []) }
    private var hasVoted: Bool { info.myRecord != nil }
    private var canSelect: Bool {
        info.canVote == true
            && info.myRecord == nil
            && info.isAvailable != false
            && auth.profile != nil
    }
    private var showResults: Bool {
        !(info.needVote == true && info.myRecord == nil && info.isAvailable != false)
    }
    private var maxVotes: Int { max(1, info.maxVoteCount ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("投票", systemImage: "chart.bar.xaxis")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ShellTheme.primaryText)
                Spacer()
                Text("\(info.voteUserCount ?? 0) 人参与")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            Text("每人最多 \(maxVotes) 票")
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)

            ForEach(items) { item in
                option(item)
            }

            if let myRecord = info.myRecord, !((myRecord.items ?? []).isEmpty) {
                Text("你已投票：\(chosenDescriptions(myRecord))")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.accent)
            }

            if let expired = info.expiredTime {
                Text("截止时间：\(NativeFormat.date(expired))")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            if !canSelect, auth.profile == nil, info.myRecord == nil {
                Text("登录后可参与投票。")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.danger)
            }

            if canSelect {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if submitting { ProgressView().tint(.white) }
                        Text(submitting ? "正在提交…" : "提交投票")
                            .font(ShellTheme.Fonts.footnote.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(ShellTheme.accent)
                .disabled(selected.isEmpty || submitting)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
        .onAppear {
            selected = myItems
        }
        .onChange(of: info.myRecord?.items ?? []) { _, value in
            selected = Set(value)
        }
    }

    private func option(_ item: NativeVoteItem) -> some View {
        Button {
            toggle(item.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: marker(for: item.id))
                        .font(.footnote)
                        .foregroundStyle(selected.contains(item.id) || myItems.contains(item.id) ? ShellTheme.accent : ShellTheme.secondaryText)
                    Text(item.description ?? "选项 \(item.id)")
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.primaryText)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if showResults {
                        Text("\(item.count ?? 0) 票")
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(ShellTheme.secondaryText)
                    }
                }

                if showResults {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ShellTheme.secondarySurface)
                            Capsule()
                                .fill(ShellTheme.accent)
                                .frame(width: geometry.size.width * fraction(item.count))
                        }
                    }
                    .frame(height: 6)

                    Text(percent(item.count))
                        .font(.system(size: 10))
                        .foregroundStyle(ShellTheme.secondaryText)
                }
            }
            .padding(10)
            .background(
                selected.contains(item.id) || myItems.contains(item.id)
                    ? ShellTheme.accentSoft
                    : ShellTheme.secondarySurface,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
    }

    private func chosenDescriptions(_ record: NativeVoteRecord) -> String {
        (record.items ?? []).compactMap { id in
            items.first { $0.id == id }?.description
        }
        .joined(separator: "、")
    }

    private func marker(for id: Int) -> String {
        if selected.contains(id) {
            return "checkmark.circle.fill"
        }
        if myItems.contains(id) {
            return "checkmark.circle"
        }
        return "circle"
    }

    private func fraction(_ count: Int?) -> CGFloat {
        let total = max(info.voteUserCount ?? 0, 1)
        return min(1, max(0, CGFloat(count ?? 0) / CGFloat(total)))
    }

    private func percent(_ count: Int?) -> String {
        let total = max(info.voteUserCount ?? 0, 1)
        return String(format: "%.2f%%", Double(count ?? 0) / Double(total) * 100)
    }

    private func toggle(_ id: Int) {
        guard canSelect else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else if selected.count < maxVotes {
            selected.insert(id)
        }
    }

    @MainActor
    private func submit() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        guard !selected.isEmpty, !submitting else { return }
        submitting = true
        errorMessage = nil
        do {
            try await app.api.castVote(topicID: topicID, items: Array(selected))
            onVoted()
        } catch {
            errorMessage = error.localizedDescription
        }
        submitting = false
    }
}
