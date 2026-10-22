import SwiftUI

/// Metadata wraps at large type without shrinking the title or hiding counts.
struct NativeTopicMetadata: View {
    var board: String? = nil
    var author: String? = nil
    var userNote: String? = nil
    var replyCount: Int? = nil
    var hitCount: Int? = nil
    var date: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !identity.isEmpty { Text(identity).fixedSize(horizontal: false, vertical: true) }
            if let userNote, !userNote.isEmpty {
                Text("备注：\(userNote)").fixedSize(horizontal: false, vertical: true)
            }
            Text(activity).fixedSize(horizontal: false, vertical: true)
        }
        .font(ShellTheme.Fonts.metadata)
        .foregroundStyle(ShellTheme.secondaryText)
    }

    private var identity: String {
        [board, author].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var activity: String {
        var parts = ["回复 \(NativeFormat.count(replyCount))"]
        if let hitCount { parts.append("点击 \(NativeFormat.count(hitCount))") }
        if let date, !date.isEmpty { parts.append(date) }
        return parts.joined(separator: " · ")
    }
}

struct NativeInlineRetry: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message).font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新加载", action: retry).frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
