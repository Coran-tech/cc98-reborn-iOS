import Foundation

struct NativeSavedTopic: Identifiable, Codable, Hashable {
    let id: Int
    let title: String
    let boardID: Int?
    let savedAt: Date
}

struct NativeReadPosition: Codable, Hashable {
    let page: Int
    let floor: Int?
    let updatedAt: Date
}

struct NativeNumericBlockRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var metric: String
    var comparison: String
    var threshold: Double
}

struct NativeLibraryData: Codable {
    var readLater: [NativeSavedTopic] = []
    var history: [NativeSavedTopic] = []
    var notes: [String: String] = [:]
    var blockedUsers: [String] = []
    var blockedKeywords: [String] = []
    var blockedUserIDs: [String]?
    var blockedBoards: [String]?
    var blockedTitleKeywords: [String]?
    var blockedContentRules: [String]?
    var blockedNumericRules: [NativeNumericBlockRule]?
    var blockedTopicIDs: [Int]?
    var drafts: [String: String]?
    var readPositions: [String: NativeReadPosition]?
    var readLaterReadIDs: [Int]?
    var pinnedBoards: [NativePinnedBoard]?
    var pinnedContactIDs: [Int]?
    var userNotes: [String: String]?
    var searchHistory: [NativeSearchEntry]?
    var draftDates: [String: Date]?
    var draftContexts: [String: NativeDraftContext]?
}


struct NativePinnedBoard: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
}

struct NativeSearchEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    let query: String
    let scope: String
    let boardID: Int?
    let boardName: String?
    let date: Date
}

struct NativeDraftContext: Codable, Hashable {
    let topicID: Int?
    let boardID: Int?
    let floor: Int?
    let title: String?
}

// The snapshot distinguishes an intentional empty edit from an absent legacy
// draft. This is shared by the editor and the production-data test harness.
struct NativeEditorDraftRecovery: Codable, Equatable {
    let title: String
    let body: String

    static func encode(title: String, body: String) throws -> String {
        let bytes = try JSONEncoder().encode(Self(title: title, body: body))
        return String(decoding: bytes, as: UTF8.self)
    }

    static func restore(snapshot: String, legacyTitle: String, legacyBody: String,
                        originalTitle: String, originalBody: String) -> Self {
        if let value = try? JSONDecoder().decode(Self.self, from: Data(snapshot.utf8)) { return value }
        return Self(title: legacyTitle.isEmpty ? originalTitle : legacyTitle,
                    body: legacyBody.isEmpty ? originalBody : legacyBody)
    }
}

struct NativeDraftItem: Identifiable, Hashable {
    enum Kind: String { case topic, vote, reply, quote, edit, message, other }
    let id: String
    let kind: Kind
    let targetID: Int?
    let quotedPostID: Int?
    let title: String
    let body: String
    let keys: [String]
    let updatedAt: Date?
    let context: NativeDraftContext?

    var kindTitle: String {
        switch kind {
        case .topic: return "主题"
        case .vote: return "投票"
        case .reply: return "回复"
        case .quote: return "引用回复"
        case .edit: return "编辑帖子"
        case .message: return "私信"
        case .other: return "旧版草稿"
        }
    }

    static func group(drafts: [String: String], dates: [String: Date], contexts: [String: NativeDraftContext]) -> [NativeDraftItem] {
        var groups: [String: [String]] = [:]
        for key in drafts.keys {
            let parts = key.split(separator: ":").map(String.init)
            let prefix = parts.first ?? key
            let groupPrefix: String
            if prefix.hasPrefix("newtopic.") { groupPrefix = "newtopic" }
            else if prefix.hasPrefix("newvote.") { groupPrefix = "newvote" }
            else if prefix.hasPrefix("edit.") { groupPrefix = "edit" }
            else { groupPrefix = prefix }
            let groupID = ([groupPrefix] + parts.dropFirst()).joined(separator: ":")
            groups[groupID, default: []].append(key)
        }
        return groups.compactMap { id, keys -> NativeDraftItem? in
            let parts = id.split(separator: ":").map(String.init)
            let prefix = parts.first ?? ""
            let target = parts.count > 1 ? Int(parts[1]) : nil
            let kind: Kind
            switch prefix {
            case "newtopic": kind = .topic
            case "newvote": kind = .vote
            case "reply": kind = .reply
            case "reply.quote": kind = .quote
            case "edit": kind = .edit
            case "pm": kind = .message
            default: kind = .other
            }
            let visibleKeys = keys.filter { !$0.contains(".settings:") }
            let bodyContextKey = target.map { "\(prefix).body:\($0)" }
            let context = keys.compactMap { contexts[$0] }.first ?? bodyContextKey.flatMap { contexts[$0] }
            let settingsKey = keys.first { $0.contains(".settings:") }
            let settings = settingsKey.flatMap { drafts[$0] }
            let hasVoteOptions: Bool
            if kind == .vote, let settings,
               let object = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any],
               let options = object["voteItems"] as? [String] {
                hasVoteOptions = options.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            } else { hasVoteOptions = false }
            // Editing can intentionally clear both fields. Its settings snapshot
            // still represents a recoverable task when the original post is known.
            guard !visibleKeys.isEmpty || hasVoteOptions || (kind == .edit && context != nil) else { return nil }
            let titleKey = keys.first { $0.contains(".title:") }
            let bodyKey = keys.first { $0.contains(".body:") } ?? visibleKeys.first { !$0.contains(".title:") }
            let title = titleKey.flatMap { drafts[$0] }.flatMap { $0.isEmpty ? nil : $0 }
                ?? context?.title ?? (target.map { "#\($0)" } ?? "未命名草稿")
            return NativeDraftItem(id: id, kind: kind, targetID: target,
                                   quotedPostID: parts.count > 2 ? Int(parts[2]) : nil,
                                   title: title, body: bodyKey.flatMap { drafts[$0] } ?? "",
                                   keys: keys.sorted(), updatedAt: keys.compactMap { dates[$0] }.max(), context: context)
        }.sorted { ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id) }
    }
}

enum NativeLibraryRules {
    static func regularExpression(_ rule: String) -> NSRegularExpression? {
        guard rule.hasPrefix("/"), let end = rule.dropFirst().lastIndex(of: "/") else { return nil }
        let flags = String(rule[rule.index(after: end)...])
        guard flags.isEmpty || flags == "i" else { return nil }
        let pattern = String(rule[rule.index(after: rule.startIndex)..<end])
        // Build 82 already treated /pattern/ as case-insensitive. Keep stored
        // rules working while also accepting the advertised /pattern/i form.
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }
    static func validationError(_ rule: String) -> String? {
        if rule.count > 500 { return "单条规则最多 500 字。" }
        if rule.hasPrefix("/"), regularExpression(rule) == nil { return "正则格式无效。请使用 /表达式/ 或 /表达式/i。" }
        return nil
    }
}

enum NativeLibraryTransferMode: String, Codable {
    case library, readLater
    var title: String { self == .library ? "本机增强备份" : "稍后再看导入导出" }
}

struct NativeLibraryImportPreview: Identifiable {
    let id = UUID()
    let backup: NativeLibraryBackup
    let accountID: Int?
    var summary: [(String, Int)] {
        let p = backup.payload
        var rows: [(String, Int)] = [("稍后再看", p.readLater.count)]
        if backup.kind == .library {
            rows.append(("置顶版面", p.pinnedBoards.count))
            rows.append(("置顶联系人", p.pinnedContactIDs.count))
            rows.append(("用户备注", p.userNotes.count))
            rows.append(("主题备注", p.notes.count))
            let ruleCounts: [Int] = [p.blockedUsers.count, p.blockedKeywords.count,
                                    p.blockedUserIDs.count, p.blockedBoards.count,
                                    p.blockedTitleKeywords.count, p.blockedContentRules.count,
                                    p.blockedNumericRules.count, p.blockedTopicIDs.count]
            rows.append(("屏蔽规则", ruleCounts.reduce(0, +)))
        }
        return rows
    }
}

struct NativeLibraryBackup: Codable {
    static let formatName = "cc98-reborn-native-enhancements"
    let format: String
    let version: Int
    let kind: NativeLibraryTransferMode
    let accountID: Int?
    let exportedAt: Date
    let payload: Payload

    struct Payload: Codable {
        var readLater: [NativeSavedTopic] = []
        var readLaterReadIDs: [Int] = []
        var pinnedBoards: [NativePinnedBoard] = []
        var pinnedContactIDs: [Int] = []
        var notes: [String: String] = [:]
        var userNotes: [String: String] = [:]
        var blockedUsers: [String] = []
        var blockedKeywords: [String] = []
        var blockedUserIDs: [String] = []
        var blockedBoards: [String] = []
        var blockedTitleKeywords: [String] = []
        var blockedContentRules: [String] = []
        var blockedNumericRules: [NativeNumericBlockRule] = []
        var blockedTopicIDs: [Int] = []
    }

    enum BackupError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }

    static func make(data: NativeLibraryData, accountID: Int?, mode: NativeLibraryTransferMode) -> Self {
        var p = Payload()
        p.readLater = data.readLater
        p.readLaterReadIDs = (data.readLaterReadIDs ?? []).filter { id in data.readLater.contains { $0.id == id } }
        if mode == .library {
            p.pinnedBoards = data.pinnedBoards ?? []
            p.pinnedContactIDs = data.pinnedContactIDs ?? []
            p.notes = data.notes; p.userNotes = data.userNotes ?? [:]
            p.blockedUsers = data.blockedUsers; p.blockedKeywords = data.blockedKeywords
            p.blockedUserIDs = data.blockedUserIDs ?? []; p.blockedBoards = data.blockedBoards ?? []
            p.blockedTitleKeywords = data.blockedTitleKeywords ?? []; p.blockedContentRules = data.blockedContentRules ?? []
            p.blockedNumericRules = data.blockedNumericRules ?? []; p.blockedTopicIDs = data.blockedTopicIDs ?? []
        }
        return Self(format: formatName, version: 1, kind: mode, accountID: accountID, exportedAt: Date(), payload: p)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decodeValidated(_ raw: Data, accountID: Int?, mode: NativeLibraryTransferMode) throws -> Self {
        func fail(_ message: String) throws -> Never { throw BackupError.invalid(message) }
        guard raw.count <= 5 * 1_024 * 1_024 else { try fail("文件超过 5 MB，无法导入。") }
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { try fail("请选择本 App 导出的 JSON 备份。") }
        // Only known fields may cross the import boundary, including nested values.
        func checkKeys(_ value: Any, allowed: Set<String>) throws {
            guard let dict = value as? [String: Any], Set(dict.keys).isSubset(of: allowed) else { try fail("备份包含未知或敏感字段，已拒绝导入。") }
        }
        try checkKeys(object, allowed: ["format", "version", "kind", "accountID", "exportedAt", "payload"])
        guard let p = object["payload"] as? [String: Any] else { try fail("备份缺少内容。") }
        let payloadKeys: Set<String> = ["readLater", "readLaterReadIDs", "pinnedBoards", "pinnedContactIDs", "notes", "userNotes", "blockedUsers", "blockedKeywords", "blockedUserIDs", "blockedBoards", "blockedTitleKeywords", "blockedContentRules", "blockedNumericRules", "blockedTopicIDs"]
        try checkKeys(p, allowed: payloadKeys)
        for item in p["readLater"] as? [Any] ?? [] { try checkKeys(item, allowed: ["id", "title", "boardID", "savedAt"]) }
        for item in p["pinnedBoards"] as? [Any] ?? [] { try checkKeys(item, allowed: ["id", "name"]) }
        for item in p["blockedNumericRules"] as? [Any] ?? [] { try checkKeys(item, allowed: ["id", "metric", "comparison", "threshold"]) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Self.self, from: raw)
        guard backup.format == formatName, backup.version == 1 else { try fail("不支持此备份格式或版本。") }
        guard backup.kind == mode else { try fail("文件类型不匹配，请在对应的备份入口导入。") }
        if mode == .library, backup.accountID != accountID { try fail("本机增强备份仅可导入同一账号；请先切换至导出账号。") }
        let value = backup.payload
        func validIDs(_ values: [Int]) -> Bool { values.count <= 10_000 && values.allSatisfy { $0 > 0 } && Set(values).count == values.count }
        guard validIDs(value.readLater.map(\.id)), validIDs(value.pinnedBoards.map(\.id)), validIDs(value.pinnedContactIDs), validIDs(value.blockedTopicIDs), validIDs(value.readLaterReadIDs) else { try fail("备份中的 ID 无效、重复或条目过多。") }
        guard value.readLater.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 2_000 && ($0.boardID == nil || $0.boardID! > 0) }),
              value.pinnedBoards.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 200 }),
              Set(value.readLaterReadIDs).isSubset(of: Set(value.readLater.map(\.id))) else { try fail("备份中的主题或版面内容无效。") }
        for (notes, limit) in [(value.notes, 500), (value.userNotes, 80)] {
            guard notes.count <= 10_000, notes.allSatisfy({ (Int($0.key) ?? 0) > 0 && Int($0.key).map(String.init) == $0.key && $0.value.count <= limit }) else { try fail("备注 ID 或长度无效。") }
        }
        for rules in [value.blockedUsers, value.blockedKeywords, value.blockedUserIDs, value.blockedBoards, value.blockedTitleKeywords, value.blockedContentRules] {
            guard rules.count <= 10_000, rules.allSatisfy({ !$0.isEmpty && $0.count <= 500 }) else { try fail("屏蔽规则长度或数量无效。") }
        }
        guard (value.blockedContentRules + value.blockedTitleKeywords).allSatisfy({ NativeLibraryRules.validationError($0) == nil }),
              Set(value.blockedNumericRules.map(\.id)).count == value.blockedNumericRules.count,
              value.blockedNumericRules.count <= 10_000,
              value.blockedNumericRules.allSatisfy({ ["like", "dislike", "total", "ratio", "reputation"].contains($0.metric) && ["<", "<=", ">", ">=", "=", "!="].contains($0.comparison) && $0.threshold.isFinite }) else { try fail("备份包含无效的筛选规则。") }
        if mode == .readLater {
            guard value.pinnedBoards.isEmpty, value.pinnedContactIDs.isEmpty, value.notes.isEmpty, value.userNotes.isEmpty,
                  value.blockedUsers.isEmpty, value.blockedKeywords.isEmpty, value.blockedUserIDs.isEmpty, value.blockedBoards.isEmpty,
                  value.blockedTitleKeywords.isEmpty, value.blockedContentRules.isEmpty, value.blockedNumericRules.isEmpty, value.blockedTopicIDs.isEmpty else { try fail("稍后再看文件包含其他账号设置，已拒绝导入。") }
        }
        return backup
    }

    func merging(into current: NativeLibraryData) -> NativeLibraryData {
        var result = current
        func unique<T: Hashable>(_ old: [T], _ added: [T]) -> [T] {
            var seen = Set(old); return old + added.filter { seen.insert($0).inserted }
        }
        let oldIDs = Set(current.readLater.map(\.id))
        result.readLater += payload.readLater.filter { !oldIDs.contains($0.id) }
        result.readLaterReadIDs = unique(current.readLaterReadIDs ?? [], payload.readLaterReadIDs.filter { !oldIDs.contains($0) })
        if kind == .library {
            let boards = current.pinnedBoards ?? []
            let ids = Set(boards.map(\.id))
            result.pinnedBoards = boards + payload.pinnedBoards.filter { !ids.contains($0.id) }
            result.pinnedContactIDs = unique(current.pinnedContactIDs ?? [], payload.pinnedContactIDs)
            result.notes.merge(payload.notes) { existing, _ in existing }
            result.userNotes = (current.userNotes ?? [:]).merging(payload.userNotes) { existing, _ in existing }
            result.blockedUsers = unique(current.blockedUsers, payload.blockedUsers)
            result.blockedKeywords = unique(current.blockedKeywords, payload.blockedKeywords)
            result.blockedUserIDs = unique(current.blockedUserIDs ?? [], payload.blockedUserIDs)
            result.blockedBoards = unique(current.blockedBoards ?? [], payload.blockedBoards)
            result.blockedTitleKeywords = unique(current.blockedTitleKeywords ?? [], payload.blockedTitleKeywords)
            result.blockedContentRules = unique(current.blockedContentRules ?? [], payload.blockedContentRules)
            let numeric = current.blockedNumericRules ?? []
            result.blockedNumericRules = numeric + payload.blockedNumericRules.filter { rule in
                !numeric.contains { $0.id == rule.id || ($0.metric == rule.metric && $0.comparison == rule.comparison && $0.threshold == rule.threshold) }
            }
            result.blockedTopicIDs = unique(current.blockedTopicIDs ?? [], payload.blockedTopicIDs)
        }
        return result
    }
}

// A rating can change wealth, prestige or reputation. Only an explicit
// reputation value or a bare signed number is a reputation delta.
enum NativeReputation {
    static func delta(in content: String?) -> Int? {
        guard let content else { return nil }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^[+-]?\d+$"#, options: .regularExpression) != nil { return Int(text) }
        for pattern in [#"风评值\s*[:：]?\s*([+-]?\d+)"#, #"([+-]?\d+)\s*风评值"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let value = Int(text[range]) else { continue }
            return value
        }
        return nil
    }
}
