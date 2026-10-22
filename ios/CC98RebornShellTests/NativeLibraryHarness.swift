#if LIBRARY_HARNESS
import Foundation

@main
struct NativeLibraryHarness {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw NSError(domain: "NativeLibraryHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks += 1
        }
        func rejects(_ name: String, _ work: () throws -> Void) throws {
            do { try work() } catch { checks += 1; return }
            throw NSError(domain: "NativeLibraryHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: \(name)"])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = #"{"readLater":[{"id":10,"title":"旧主题","boardID":12,"savedAt":0}],"history":[],"notes":{"10":"旧备注"},"blockedUsers":[],"blockedKeywords":[],"drafts":{"reply:10":"旧回复","edit.title:70":"旧编辑","newtopic.settings:12":"{}"}}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("library-7.json"))
        let library = NativeLibrary(accountID: 7, directory: dir)
        try expect(library.readLater.first?.id == 10 && library.note(for: 10) == "旧备注", "legacy decoding")
        try expect(library.lastSaveError == nil && library.pinnedBoards.isEmpty, "optional additions migrate")
        try expect(library.draftItems.count == 2, "settings-only drafts hidden")
        try expect(library.draft(for: "reply:10") == "旧回复", "legacy draft key retained")
        try expect(library.setDraft("新私信", for: "pm:9"), "save draft success")
        library.setDraftContext(for: "edit.body:70", topicID: 10, boardID: 12, floor: 3, title: "原主题")
        library.setDraft("正文", for: "edit.body:70")
        try expect(library.draftItems.first(where: { $0.kind == .edit })?.keys.count == 2, "editing keys grouped")
        try expect(library.draftItems.first(where: { $0.kind == .edit })?.context?.floor == 3, "real post context preserved")
        try expect(library.setDrafts(["newvote.title:12": "投票标题", "newvote.settings:12": "{\"options\":[\"A\",\"B\"]}"]), "atomic draft group save")
        let vote = library.draftItems.first { $0.kind == .vote }!
        try expect(library.removeDraft(vote), "group deletion saved")
        try expect(library.draft(for: "newvote.settings:12").isEmpty, "group deletion removes settings")
        library.togglePinnedBoard(id: 12, name: "测试版面")
        library.togglePinnedContact(userID: 9)
        library.setUserNote(String(repeating: "字", count: 90), for: 9)
        library.setReadLaterRead(10, read: true)
        for index in 0..<25 { library.recordSearch("词\(index)", scope: "all") }
        try expect(library.searchHistory.count == 20, "bounded search history")
        library.recordSearch("词24", scope: "all")
        try expect(library.searchHistory.count == 20 && library.searchHistory.first?.query == "词24", "history deduplication")
        let restored = NativeLibrary(accountID: 7, directory: dir)
        try expect(restored.isBoardPinned(12) && restored.isContactPinned(9), "pins round trip")
        try expect(restored.userNote(for: 9).count == 80 && restored.isReadLaterRead(10), "notes/read state round trip")
        try expect(restored.draft(for: "pm:9") == "新私信", "private draft restart recovery")
        let other = NativeLibrary(accountID: 8, directory: dir)
        try expect(other.readLater.isEmpty && other.draftItems.isEmpty, "account isolation")
        other.setUserNote("其他账号", for: 9)
        try expect(restored.userNote(for: 9) != other.userNote(for: 9), "independent account notes")
        let raw = try restored.exportBackup(mode: .library)
        let object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let payload = object["payload"] as! [String: Any]
        try expect(payload["drafts"] == nil && payload["history"] == nil && payload["searchHistory"] == nil, "private content excluded from export")
        try rejects("cross-account full backup") { _ = try other.previewImport(raw, mode: .library) }
        try rejects("wrong mode") { _ = try restored.previewImport(raw, mode: .readLater) }
        let laterRaw = try restored.exportBackup(mode: .readLater)
        let laterPreview = try other.previewImport(laterRaw, mode: .readLater)
        try expect(other.importBackup(laterPreview), "read-later merge to current account")
        try expect(other.readLater.count == 1 && other.userNote(for: 9) == "其他账号", "merge retains unrelated current data")
        restored.setNote("本机优先", for: 10)
        let samePreview = try restored.previewImport(raw, mode: .library)
        try expect(restored.importBackup(samePreview), "same-account merge")
        try expect(restored.note(for: 10) == "本机优先" && restored.readLater.count == 1, "merge keeps current conflict and avoids duplicate")
        for field in ["access_token", "refreshToken", "drafts", "clientSecret"] {
            var bad = object; var nested = payload; nested[field] = "secret"; bad["payload"] = nested
            let bytes = try JSONSerialization.data(withJSONObject: bad)
            try rejects("unknown credential field \(field)") { _ = try restored.previewImport(bytes, mode: .library) }
        }
        var bad = object; bad["version"] = 99
        try rejects("future backup version") { _ = try restored.previewImport(JSONSerialization.data(withJSONObject: bad), mode: .library) }
        bad = object; var nested = payload; nested["readLater"] = [["id": -1, "title": "坏 ID", "savedAt": "2026-01-01T00:00:00Z"]]; bad["payload"] = nested
        try rejects("invalid id") { _ = try restored.previewImport(JSONSerialization.data(withJSONObject: bad), mode: .library) }
        bad = object; nested = payload; nested["userNotes"] = ["access_token": "credential"]; bad["payload"] = nested
        try rejects("credential dictionary key") { _ = try restored.previewImport(JSONSerialization.data(withJSONObject: bad), mode: .library) }
        var failWrites = true
        let failing = NativeLibrary(accountID: 90, directory: dir, writeData: { data, url in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }; try data.write(to: url, options: .atomic)
        })
        try expect(!failing.setDraft("不能丢", for: "pm:9"), "write failure is returned")
        try expect(failing.lastSaveError != nil && failing.lastSavedAt == nil && failing.draft(for: "pm:9") == "不能丢", "failed save stays editable without false saved status")
        let failPreview = try failing.previewImport(laterRaw, mode: .readLater)
        try expect(!failing.importBackup(failPreview) && failing.readLater.isEmpty, "failed import does not publish candidate")
        failWrites = false
        try expect(failing.retrySave() && failing.lastSaveError == nil, "write retry succeeds")
        try expect(NativeLibrary(accountID: 90, directory: dir).draft(for: "pm:9") == "不能丢", "retry persists pending edits")
        let corruptURL = dir.appendingPathComponent("library-91.json")
        let corrupt = Data("broken-json".utf8); try corrupt.write(to: corruptURL)
        let unreadable = NativeLibrary(accountID: 91, directory: dir)
        try expect(!unreadable.setDraft("新内容", for: "pm:9"), "corrupt source prevents overwrite")
        let retained = try Data(contentsOf: corruptURL)
        try expect(retained == corrupt, "original corrupt file retained")
        let preview = try restored.previewImport(raw, mode: .library)
        restored.setAccount(8)
        try expect(!restored.importBackup(preview), "account switch invalidates import preview")
        let rules = NativeLibrary(accountID: 92, directory: dir)
        rules.addBlockedBoard("12")
        try expect(rules.isBoardBlocked(id: 12, name: nil) && !rules.isBoardBlocked(id: 112, name: "版面 12"), "numeric board ID exact match")
        try expect(rules.addBlockedContentRule("/测试/i") && rules.isContentBlocked("这是测试"), "advertised regex syntax works")
        try expect(!rules.addBlockedContentRule("/[/i"), "invalid regex rejected")
        rules.addNumericRule(NativeNumericBlockRule(metric: "like", comparison: "=", threshold: 0))
        let missing = try JSONDecoder().decode(NativePost.self, from: Data(#"{"id":1}"#.utf8))
        let zero = try JSONDecoder().decode(NativePost.self, from: Data(#"{"id":2,"likeCount":0}"#.utf8))
        try expect(!rules.shouldBlock(post: missing) && rules.shouldBlock(post: zero), "unknown metric differs from zero")
        rules.clearBlockingRules()
        rules.addNumericRule(NativeNumericBlockRule(metric: "ratio", comparison: ">", threshold: 100))
        let noDislikes = try JSONDecoder().decode(NativePost.self, from: Data(#"{"id":3,"likeCount":1,"dislikeCount":0}"#.utf8))
        let noVotes = try JSONDecoder().decode(NativePost.self, from: Data(#"{"id":4,"likeCount":0,"dislikeCount":0}"#.utf8))
        try expect(rules.shouldBlock(post: noDislikes) && !rules.shouldBlock(post: noVotes), "ratio infinity and unknown boundary")
        try expect(NativeReputation.delta(in: "财富 +100 风评值 -2") == -2 && NativeReputation.delta(in: "威望 +5") == nil && NativeReputation.delta(in: "+3") == 3, "reputation semantics")
        print("NativeLibraryHarness: \(checks) checks passed")
    }
}
#endif
