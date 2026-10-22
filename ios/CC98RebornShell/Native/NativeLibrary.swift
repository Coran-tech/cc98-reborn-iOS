import Foundation
import Combine

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
    @Published private(set) var pinnedBoards: [NativePinnedBoard] = []
    @Published private(set) var pinnedContactIDs: [Int] = []
    @Published private(set) var userNotes: [String: String] = [:]
    @Published private(set) var searchHistory: [NativeSearchEntry] = []
    @Published private(set) var readLaterReadIDs: [Int] = []
    @Published private(set) var lastSaveError: String?
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var draftItems: [NativeDraftItem] = []
    private var draftDates: [String: Date] = [:]
    private var draftContexts: [String: NativeDraftContext] = [:]
    private var drafts: [String: String] = [:]
    private var readPositions: [String: NativeReadPosition] = [:]

    private var data = NativeLibraryData()
    private var fileURL: URL
    private let directory: URL
    private var accountID: Int?

    private let writeData: (Data, URL) throws -> Void
    private var unreadableStorage = false

    init(accountID: Int? = nil, directory: URL? = nil,
         writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appendingPathComponent("CC98Reborn", isDirectory: true)
        self.accountID = accountID
        self.writeData = writeData
        self.fileURL = self.directory.appendingPathComponent(accountID.map { "library-\($0).json" } ?? "library.json")
        load()
    }

    func setAccount(_ id: Int?) {
        guard accountID != id, save() else { return }
        accountID = id
        fileURL = directory.appendingPathComponent(id.map { "library-\($0).json" } ?? "library.json")
        apply(NativeLibraryData())
        lastSaveError = nil
        lastSavedAt = nil
        unreadableStorage = false
        load()
    }

    // MARK: Read later

    func isReadLater(_ topicID: Int) -> Bool {
        readLater.contains { $0.id == topicID }
    }

    func toggleReadLater(_ topic: NativeTopic) {
        if isReadLater(topic.id) {
            readLater.removeAll { $0.id == topic.id }
            readLaterReadIDs.removeAll { $0 == topic.id }
        } else {
            readLater.insert(saved(topic), at: 0)
        }
        save()
    }

    func addReadLater(topicID: Int, title: String?, boardID: Int?) {
        guard topicID > 0, !isReadLater(topicID) else { return }
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
        readLaterReadIDs.removeAll { $0 == topicID }
        save()
    }

    func clearReadLater() {
        readLater = []
        readLaterReadIDs = []
        save()
    }

    // MARK: History

    func recordHistory(_ topic: NativeTopic) {
        history.removeAll { $0.id == topic.id }
        history.insert(saved(topic), at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        if isReadLater(topic.id), !readLaterReadIDs.contains(topic.id) { readLaterReadIDs.append(topic.id) }
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
        blockedBoards.contains { rule in
            if let boardID = Int(rule) { return boardID == id }
            return name?.localizedCaseInsensitiveContains(rule) == true
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

        if let expression = NativeLibraryRules.regularExpression(rule) {
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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
        return text.lowercased().components(separatedBy: needle.lowercased()).count - 1
    }

    private func metricValue(_ metric: String, post: NativePost) -> Double? {
        let likes = post.likeCount.map(Double.init)
        let dislikes = post.dislikeCount.map(Double.init)
        switch metric {
        case "like":
            return likes
        case "dislike":
            return dislikes
        case "total":
            guard let likes, let dislikes else { return nil }
            return likes + dislikes
        case "ratio":
            guard let likes, let dislikes, likes + dislikes > 0 else { return nil }
            return dislikes == 0 ? .infinity : likes / dislikes
        case "reputation":
            let values = (post.awards ?? []).compactMap { award -> Double? in
                NativeReputation.delta(in: award.content).map(Double.init)
            }
            return values.isEmpty ? nil : values.reduce(0, +)
        default:
            return nil
        }
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

    @discardableResult
    func addBlockedTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedTitleKeywords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        if let error = NativeLibraryRules.validationError(trimmed) { lastSaveError = error; return false }
        blockedTitleKeywords.append(trimmed)
        return save()
    }

    func removeBlockedTitle(_ value: String) {
        blockedTitleKeywords.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    @discardableResult
    func addBlockedContentRule(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedContentRules.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        if let error = NativeLibraryRules.validationError(trimmed) { lastSaveError = error; return false }
        blockedContentRules.append(trimmed)
        return save()
    }

    func removeBlockedContentRule(_ value: String) {
        blockedContentRules.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        save()
    }

    func addNumericRule(_ rule: NativeNumericBlockRule) {
        guard rule.threshold.isFinite else { lastSaveError = "阈值必须是有限数字。"; return }
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

    @discardableResult
    func setDraft(_ value: String, for key: String) -> Bool {
        setDrafts([key: value])
    }

    @discardableResult
    func setDrafts(_ values: [String: String]) -> Bool {
        let date = Date()
        for (key, value) in values {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                drafts.removeValue(forKey: key)
                draftDates.removeValue(forKey: key)
            } else {
                drafts[key] = value
                draftDates[key] = date
            }
        }
        refreshDraftItems()
        return save()
    }

    @discardableResult
    func clearDraft(for key: String) -> Bool {
        drafts.removeValue(forKey: key)
        draftDates.removeValue(forKey: key)
        draftContexts.removeValue(forKey: key)
        refreshDraftItems()
        return save()
    }

    func setDraftContext(for key: String, topicID: Int? = nil, boardID: Int? = nil,
                         floor: Int? = nil, title: String? = nil) {
        let context = NativeDraftContext(topicID: topicID, boardID: boardID, floor: floor, title: title)
        guard draftContexts[key] != context else { return }
        draftContexts[key] = context
        refreshDraftItems()
        save()
    }

    @discardableResult
    func removeDraft(_ item: NativeDraftItem) -> Bool {
        for key in item.keys {
            drafts.removeValue(forKey: key)
            draftDates.removeValue(forKey: key)
            draftContexts.removeValue(forKey: key)
        }
        refreshDraftItems()
        return save()
    }

    private func refreshDraftItems() {
        draftItems = NativeDraftItem.group(drafts: drafts, dates: draftDates, contexts: draftContexts)
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let raw = try Data(contentsOf: fileURL)
            apply(try JSONDecoder().decode(NativeLibraryData.self, from: raw))
        } catch {
            unreadableStorage = true
            lastSaveError = "本机数据无法读取，原文件已保留。请恢复可用文件后重开 App。\(error.localizedDescription)"
        }
    }

    private func apply(_ decoded: NativeLibraryData) {
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
        pinnedBoards = decoded.pinnedBoards ?? []
        pinnedContactIDs = decoded.pinnedContactIDs ?? []
        userNotes = decoded.userNotes ?? [:]
        searchHistory = decoded.searchHistory ?? []
        readLaterReadIDs = decoded.readLaterReadIDs ?? []
        draftDates = decoded.draftDates ?? [:]
        draftContexts = decoded.draftContexts ?? [:]
        refreshDraftItems()
    }

    private func snapshot() -> NativeLibraryData {
        NativeLibraryData(
            readLater: readLater, history: history, notes: notes,
            blockedUsers: blockedUsers, blockedKeywords: blockedKeywords,
            blockedUserIDs: blockedUserIDs, blockedBoards: blockedBoards,
            blockedTitleKeywords: blockedTitleKeywords, blockedContentRules: blockedContentRules,
            blockedNumericRules: blockedNumericRules, blockedTopicIDs: blockedTopicIDs,
            drafts: drafts, readPositions: readPositions, readLaterReadIDs: readLaterReadIDs,
            pinnedBoards: pinnedBoards, pinnedContactIDs: pinnedContactIDs, userNotes: userNotes,
            searchHistory: searchHistory, draftDates: draftDates, draftContexts: draftContexts
        )
    }

    @discardableResult
    private func persist(_ candidate: NativeLibraryData) -> Bool {
        guard !unreadableStorage else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeData(JSONEncoder().encode(candidate), fileURL)
            data = candidate
            lastSaveError = nil
            lastSavedAt = Date()
            return true
        } catch {
            lastSaveError = "尚未保存到本机：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func save() -> Bool { persist(snapshot()) }

    @discardableResult
    func retrySave() -> Bool { save() }

    // MARK: Local enhancements

    func isBoardPinned(_ id: Int) -> Bool { pinnedBoards.contains { $0.id == id } }
    @discardableResult
    func togglePinnedBoard(id: Int, name: String) -> Bool {
        guard id > 0 else { return false }
        if isBoardPinned(id) { pinnedBoards.removeAll { $0.id == id } }
        else { pinnedBoards.append(NativePinnedBoard(id: id, name: name)) }
        return save()
    }

    func isContactPinned(_ id: Int) -> Bool { pinnedContactIDs.contains(id) }
    @discardableResult
    func togglePinnedContact(userID: Int) -> Bool {
        guard userID > 0 else { return false }
        if isContactPinned(userID) { pinnedContactIDs.removeAll { $0 == userID } }
        else { pinnedContactIDs.append(userID) }
        return save()
    }

    func userNote(for id: Int) -> String { userNotes[String(id)] ?? "" }
    @discardableResult
    func setUserNote(_ note: String, for id: Int) -> Bool {
        guard id > 0 else { return false }
        let value = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        userNotes[String(id)] = value.isEmpty ? nil : value
        return save()
    }

    func isReadLaterRead(_ id: Int) -> Bool { readLaterReadIDs.contains(id) }
    func setReadLaterRead(_ id: Int, read: Bool) {
        guard isReadLater(id) else { return }
        readLaterReadIDs.removeAll { $0 == id }
        if read { readLaterReadIDs.append(id) }
        save()
    }

    func recordSearch(_ query: String, scope: String, boardID: Int? = nil, boardName: String? = nil) {
        let value = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !value.isEmpty else { return }
        searchHistory.removeAll { $0.query == value && $0.scope == scope && $0.boardID == boardID }
        searchHistory.insert(NativeSearchEntry(query: value, scope: scope, boardID: boardID, boardName: boardName, date: Date()), at: 0)
        searchHistory = Array(searchHistory.prefix(20))
        save()
    }

    func removeSearch(_ id: UUID) { searchHistory.removeAll { $0.id == id }; save() }
    func clearSearchHistory() { searchHistory = []; save() }

    func exportBackup(mode: NativeLibraryTransferMode) throws -> Data {
        try NativeLibraryBackup.make(data: snapshot(), accountID: accountID, mode: mode).encoded()
    }

    func previewImport(_ raw: Data, mode: NativeLibraryTransferMode) throws -> NativeLibraryImportPreview {
        let backup = try NativeLibraryBackup.decodeValidated(raw, accountID: accountID, mode: mode)
        return NativeLibraryImportPreview(backup: backup, accountID: accountID)
    }

    @discardableResult
    func importBackup(_ preview: NativeLibraryImportPreview) -> Bool {
        guard preview.accountID == accountID else { lastSaveError = "账号已切换，请重新选择备份。"; return false }
        let candidate = preview.backup.merging(into: snapshot())
        guard persist(candidate) else { return false }
        apply(candidate)
        return true
    }
}
