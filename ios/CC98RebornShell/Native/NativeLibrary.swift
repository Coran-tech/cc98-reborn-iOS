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

private struct NativeLibraryData: Codable {
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
}

// Local-only Reborn conveniences: read later, history, topic notes and
// user/keyword filters. Nothing here is uploaded and no token is stored.
@MainActor
final class NativeLibrary: ObservableObject {
    @Published private(set) var readLater: [NativeSavedTopic] = []
    @Published private(set) var history: [NativeSavedTopic] = []
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var blockedUsers: [String] = []
    @Published private(set) var blockedKeywords: [String] = []
    @Published private(set) var blockedUserIDs: [String] = []
    @Published private(set) var blockedBoards: [String] = []
    @Published private(set) var blockedTitleKeywords: [String] = []
    @Published private(set) var blockedContentRules: [String] = []
    @Published private(set) var blockedNumericRules: [NativeNumericBlockRule] = []
    @Published private(set) var blockedTopicIDs: [Int] = []
    private var drafts: [String: String] = [:]
    private var readPositions: [String: NativeReadPosition] = [:]

    private var data = NativeLibraryData()
    private var fileURL: URL
    private let directory: URL
    private var accountID: Int?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("CC98Reborn", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("library.json")
        load()
    }

    func setAccount(_ id: Int?) {
        guard accountID != id else { return }
        save()
        accountID = id
        fileURL = directory.appendingPathComponent(id.map { "library-\($0).json" } ?? "library.json")

        data = NativeLibraryData()
        readLater = []
        history = []
        notes = [:]
        blockedUsers = []
        blockedKeywords = []
        blockedUserIDs = []
        blockedBoards = []
        blockedTitleKeywords = []
        blockedContentRules = []
        blockedNumericRules = []
        blockedTopicIDs = []
        drafts = [:]
        readPositions = [:]
        load()
    }

    // MARK: Read later

    func isReadLater(_ topicID: Int) -> Bool {
        readLater.contains { $0.id == topicID }
    }

    func toggleReadLater(_ topic: NativeTopic) {
        if isReadLater(topic.id) {
            readLater.removeAll { $0.id == topic.id }
        } else {
            readLater.insert(saved(topic), at: 0)
        }
        save()
    }

    func addReadLater(topicID: Int, title: String?, boardID: Int?) {
        guard !isReadLater(topicID) else { return }
        readLater.insert(
            NativeSavedTopic(
                id: topicID,
                title: title ?? "主题 #\(topicID)",
                boardID: boardID,
                savedAt: Date()
            ),
            at: 0
        )
        save()
    }

    func removeReadLater(_ topicID: Int) {
        readLater.removeAll { $0.id == topicID }
        save()
    }

    func clearReadLater() {
        readLater = []
        save()
    }

    // MARK: History

    func recordHistory(_ topic: NativeTopic) {
        history.removeAll { $0.id == topic.id }
        history.insert(saved(topic), at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        save()
    }

    func clearHistory() {
        history = []
        save()
    }

    // MARK: Notes

    func note(for topicID: Int) -> String {
        notes[String(topicID)] ?? ""
    }

    func setNote(_ value: String, for topicID: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notes.removeValue(forKey: String(topicID))
        } else {
            notes[String(topicID)] = String(trimmed.prefix(500))
        }
        save()
    }

    // MARK: Filters

    func isTopicBlocked(_ topicID: Int) -> Bool {
        blockedTopicIDs.contains(topicID)
    }

    func addBlockedTopic(_ topicID: Int) {
        guard !blockedTopicIDs.contains(topicID) else { return }
        blockedTopicIDs.append(topicID)
        save()
    }

    func removeBlockedTopic(_ topicID: Int) {
        blockedTopicIDs.removeAll { $0 == topicID }
        save()
    }

    func isUserBlocked(_ name: String?) -> Bool {
        isUserBlocked(id: nil, name: name)
    }

    func isUserBlocked(id: Int?, name: String?) -> Bool {
        let candidates = [name, id.map(String.init)].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return false }
        let rules = blockedUsers + blockedUserIDs
        return rules.contains { rule in
            let value = rule.lowercased()
            return candidates.contains { $0 == value }
        }
    }

    func isBoardBlocked(id: Int?, name: String?) -> Bool {
        let candidates = [name, id.map(String.init)].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return false }
        return blockedBoards.contains { rule in
            let value = rule.lowercased()
            return candidates.contains { $0 == value || $0.localizedCaseInsensitiveContains(value) }
        }
    }

    func isTitleBlocked(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return matchesAnyRule(title, rules: blockedTitleKeywords)
    }

    func isContentBlocked(_ content: String?) -> Bool {
        guard let content, !content.isEmpty else { return false }
        if blockedKeywords.contains(where: { !$0.isEmpty && content.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return blockedContentRules.contains { matchesContentRule($0, in: content) }
    }

    func shouldBlock(post: NativePost) -> Bool {
        if isUserBlocked(id: post.userId, name: post.userName) { return true }
        if isContentBlocked(post.content) { return true }
        return blockedNumericRules.contains { rule in
            guard let value = metricValue(rule.metric, post: post) else { return false }
            return compare(value, rule.comparison, rule.threshold)
        }
    }

    private func matchesAnyRule(_ text: String, rules: [String]) -> Bool {
        rules.contains { rule in
            matchesContentRule(rule, in: text)
        }
    }

    private func matchesContentRule(_ raw: String, in text: String) -> Bool {
        let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return false }

        if rule.count > 2, rule.hasPrefix("/"), rule.hasSuffix("/") {
            let pattern = String(rule.dropFirst().dropLast())
            return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
                .map { $0.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil } ?? false
        }

        let countPattern = #"^(.+?)\s*(>=|<=|>|<|=)\s*(\d+)$"#
        if let regex = try? NSRegularExpression(pattern: countPattern),
           let match = regex.firstMatch(in: rule, range: NSRange(location: 0, length: (rule as NSString).length)) {
            let ns = rule as NSString
            var needle = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if needle.hasPrefix("\""), needle.hasSuffix("\""), needle.count >= 2 {
                needle = String(needle.dropFirst().dropLast())
            }
            let comparator = ns.substring(with: match.range(at: 2))
            let threshold = Double(ns.substring(with: match.range(at: 3))) ?? 0
            let count = occurrenceCount(of: needle, in: text)
            return compare(Double(count), comparator, threshold)
        }

        return text.localizedCaseInsensitiveContains(rule)
    }

    private func occurrenceCount(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        let ns = text as NSString
        return ns.components(separatedBy: needle).count - 1
    }

    private func metricValue(_ metric: String, post: NativePost) -> Double? {
        let likes = Double(post.likeCount ?? 0)
        let dislikes = Double(post.dislikeCount ?? 0)
        switch metric {
        case "like":
            return likes
        case "dislike":
            return dislikes
        case "total":
            return likes + dislikes
        case "ratio":
            return dislikes > 0 ? likes / dislikes : (likes > 0 ? likes : 0)
        case "reputation":
            let values = (post.awards ?? []).compactMap { award -> Double? in
                guard let content = award.content, content.contains("风评值") else { return nil }
                return signedNumber(in: content).map(Double.init)
            }
            return values.isEmpty ? nil : values.reduce(0, +)
        default:
            return nil
        }
    }

    private func signedNumber(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "([+-]?\\d+)") else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    private func compare(_ value: Double, _ comparison: String, _ threshold: Double) -> Bool {
        switch comparison {
        case ">": return value > threshold
        case ">=": return value >= threshold
        case "<": return value < threshold
        case "<=": return value <= threshold
        case "=": return value == threshold
        case "!=": return value != threshold
        default: return false
        }
    }

    func addBlockedUser(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedUsers.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        blockedUsers.append(trimmed)
        save()
    }

    func removeBlockedUser(_ value: String) {
        blockedUsers.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    func addBlockedKeyword(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedKeywords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        blockedKeywords.append(trimmed)
        save()
    }

    func removeBlockedKeyword(_ value: String) {
        blockedKeywords.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    func addBlockedUserID(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedUserIDs.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        blockedUserIDs.append(trimmed)
        save()
    }

    func removeBlockedUserID(_ value: String) {
        blockedUserIDs.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    func addBlockedBoard(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedBoards.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        blockedBoards.append(trimmed)
        save()
    }

    func removeBlockedBoard(_ value: String) {
        blockedBoards.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    func addBlockedTitle(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedTitleKeywords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        blockedTitleKeywords.append(trimmed)
        save()
    }

    func removeBlockedTitle(_ value: String) {
        blockedTitleKeywords.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    func addBlockedContentRule(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedContentRules.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        blockedContentRules.append(trimmed)
        save()
    }

    func removeBlockedContentRule(_ value: String) {
        blockedContentRules.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    func addNumericRule(_ rule: NativeNumericBlockRule) {
        blockedNumericRules.append(rule)
        save()
    }

    func removeNumericRule(_ id: UUID) {
        blockedNumericRules.removeAll { $0.id == id }
        save()
    }

    func clearBlockingRules() {
        blockedUsers = []
        blockedKeywords = []
        blockedUserIDs = []
        blockedBoards = []
        blockedTitleKeywords = []
        blockedContentRules = []
        blockedNumericRules = []
        blockedTopicIDs = []
        save()
    }

    // MARK: Drafts and reading position

    func draft(for key: String) -> String {
        drafts[key] ?? ""
    }

    func setDraft(_ value: String, for key: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = value
        }
        save()
    }

    func clearDraft(for key: String) {
        drafts.removeValue(forKey: key)
        save()
    }

    func lastPosition(for topicID: Int) -> NativeReadPosition? {
        readPositions[String(topicID)]
    }

    func recordPosition(topicID: Int, page: Int, floor: Int?) {
        guard page > 0 else { return }
        readPositions[String(topicID)] = NativeReadPosition(
            page: page,
            floor: floor,
            updatedAt: Date()
        )
        save()
    }

    // MARK: Storage

    private func saved(_ topic: NativeTopic) -> NativeSavedTopic {
        NativeSavedTopic(
            id: topic.id,
            title: topic.title ?? "主题 #\(topic.id)",
            boardID: topic.boardId,
            savedAt: Date()
        )
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(NativeLibraryData.self, from: raw) else { return }
        data = decoded
        readLater = decoded.readLater
        history = decoded.history
        notes = decoded.notes
        blockedUsers = decoded.blockedUsers
        blockedKeywords = decoded.blockedKeywords
        blockedUserIDs = decoded.blockedUserIDs ?? []
        blockedBoards = decoded.blockedBoards ?? []
        blockedTitleKeywords = decoded.blockedTitleKeywords ?? []
        blockedContentRules = decoded.blockedContentRules ?? []
        blockedNumericRules = decoded.blockedNumericRules ?? []
        blockedTopicIDs = decoded.blockedTopicIDs ?? []
        drafts = decoded.drafts ?? [:]
        readPositions = decoded.readPositions ?? [:]
    }

    private func save() {
        data = NativeLibraryData(
            readLater: readLater,
            history: history,
            notes: notes,
            blockedUsers: blockedUsers,
            blockedKeywords: blockedKeywords,
            blockedUserIDs: blockedUserIDs,
            blockedBoards: blockedBoards,
            blockedTitleKeywords: blockedTitleKeywords,
            blockedContentRules: blockedContentRules,
            blockedNumericRules: blockedNumericRules,
            blockedTopicIDs: blockedTopicIDs,
            drafts: drafts,
            readPositions: readPositions
        )
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }
}
