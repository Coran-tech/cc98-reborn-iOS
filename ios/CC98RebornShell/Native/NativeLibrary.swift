import Foundation

struct NativeSavedTopic: Identifiable, Codable, Hashable {
    let id: Int
    let title: String
    let boardID: Int?
    let savedAt: Date
}

private struct NativeLibraryData: Codable {
    var readLater: [NativeSavedTopic] = []
    var history: [NativeSavedTopic] = []
    var notes: [String: String] = [:]
    var blockedUsers: [String] = []
    var blockedKeywords: [String] = []
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

    private var data = NativeLibraryData()
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("CC98Reborn", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("library.json")
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

    func isUserBlocked(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return blockedUsers.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func isContentBlocked(_ content: String?) -> Bool {
        guard let content, !content.isEmpty else { return false }
        return blockedKeywords.contains { !$0.isEmpty && content.localizedCaseInsensitiveContains($0) }
    }

    func addBlockedUser(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUserBlocked(trimmed) else { return }
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
    }

    private func save() {
        data = NativeLibraryData(
            readLater: readLater,
            history: history,
            notes: notes,
            blockedUsers: blockedUsers,
            blockedKeywords: blockedKeywords
        )
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }
}
