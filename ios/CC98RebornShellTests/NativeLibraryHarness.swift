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
        library.setDraftContext(for: "edit.body:71", topicID: 10, floor: 4, title: "清空编辑")
        library.setDrafts(["edit.title:71": "", "edit.body:71": "", "edit.settings:71": "{\"title\":\"\",\"body\":\"\"}"])
        try expect(library.draftItems.contains { $0.id == "edit:71" && $0.context?.floor == 4 }, "intentionally empty edit remains recoverable")
        let emptyEdit = try NativeEditorDraftRecovery.encode(title: "", body: " \n ")
        let recoveredEdit = NativeEditorDraftRecovery.restore(snapshot: emptyEdit, legacyTitle: "旧标题", legacyBody: "旧内容", originalTitle: "原标题", originalBody: "原正文")
        try expect(recoveredEdit.title.isEmpty && recoveredEdit.body == " \n ", "snapshot restores intentionally empty title and whitespace verbatim")
        for fields in [("", ""), ("保留标题", ""), ("", "保留正文")] {
            let snapshot = try NativeEditorDraftRecovery.encode(title: fields.0, body: fields.1)
            let recovered = NativeEditorDraftRecovery.restore(snapshot: snapshot, legacyTitle: "旧标题", legacyBody: "旧内容", originalTitle: "原标题", originalBody: "原正文")
            try expect(recovered.title == fields.0 && recovered.body == fields.1, "empty field snapshot is authoritative")
        }
        let legacyEdit = NativeEditorDraftRecovery.restore(snapshot: "", legacyTitle: "旧标题", legacyBody: "", originalTitle: "原标题", originalBody: "原正文")
        try expect(legacyEdit.title == "旧标题" && legacyEdit.body == "原正文", "legacy absent fields retain original post values")
        let malformedEdit = NativeEditorDraftRecovery.restore(snapshot: "broken-json", legacyTitle: "", legacyBody: "旧内容", originalTitle: "原标题", originalBody: "原正文")
        try expect(malformedEdit.title == "原标题" && malformedEdit.body == "旧内容", "malformed edit snapshot falls back to legacy values")
        library.setDraft("{\"voteItems\":[\"选项 A\",\"\"]}", for: "newvote.settings:13")
        try expect(library.draftItems.contains { $0.id == "newvote:13" }, "options-only vote draft visible in draft center")
        library.clearDraft(for: "newvote.settings:13")
        library.setDraft(#"{"voteItems":[""," "]}"#, for: "newvote.settings:13")
        try expect(!library.draftItems.contains { $0.id == "newvote:13" }, "empty vote options do not create ghost draft")
        library.clearDraft(for: "newvote.settings:13")
        try expect(library.setDrafts(["newvote.title:12": "投票标题", "newvote.settings:12": "{\"options\":[\"A\",\"B\"]}"]), "atomic draft group save")
        let vote = library.draftItems.first { $0.kind == .vote }!
        try expect(library.removeDraft(vote), "group deletion saved")
        try expect(library.draft(for: "newvote.settings:12").isEmpty, "group deletion removes settings")
        var draftWriteCount = 0
        let batched = NativeLibrary(accountID: 93, directory: dir, writeData: { data, url in
            draftWriteCount += 1
            try data.write(to: url, options: .atomic)
        })
        try expect(batched.setDrafts(["edit.title:1": "标题", "edit.body:1": "正文", "edit.settings:1": "{}"]), "draft batch persists")
        try expect(draftWriteCount == 1, "one disk write for complete draft group")
        try expect(batched.clearDrafts(for: ["edit.title:1", "edit.body:1", "edit.settings:1"]), "clear draft batch persists")
        try expect(draftWriteCount == 2 && NativeLibrary(accountID: 93, directory: dir).draftItems.isEmpty, "one disk write removes complete draft group")
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
        try expect(samePreview.summary.count == 6 && samePreview.summary.first?.1 == 1, "import preview lists actual payload counts")
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
        try expect(rules.addBlockedContentRule("/Reborn/") && rules.isContentBlocked("REBORN"), "legacy slash regex remains case-insensitive")
        try expect(rules.addBlockedTitle("/Campus/i") && rules.isTitleBlocked("CAMPUS"), "explicit insensitive regex works in title rules")
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

        let undoLibrary = NativeLibrary(accountID: 94, directory: dir)
        for id in [10, 11, 12] { undoLibrary.addReadLater(topicID: id, title: "主题 \(id)", boardID: 12) }
        undoLibrary.setReadLaterRead(11, read: true)
        let originalItems = undoLibrary.readLater
        undoLibrary.removeReadLater(11)
        let removedMiddle = undoLibrary.readLaterUndo!.id
        try expect(!undoLibrary.isReadLater(11) && !undoLibrary.isReadLaterRead(11), "remove captures item without leaving read state")
        try expect(undoLibrary.undoReadLaterRemoval(removedMiddle), "undo restores the removed item")
        try expect(undoLibrary.readLater == originalItems && undoLibrary.isReadLaterRead(11), "undo preserves original item metadata, position and read state")
        try expect(!undoLibrary.undoReadLaterRemoval(removedMiddle), "undo is single-use")
        try expect(NativeLibrary(accountID: 94, directory: dir).readLater == originalItems, "undo persists restored item")
        undoLibrary.removeReadLater(11)
        let supersededUndo = undoLibrary.readLaterUndo!.id
        undoLibrary.removeReadLater(12)
        let latestUndo = undoLibrary.readLaterUndo!.id
        try expect(!undoLibrary.undoReadLaterRemoval(supersededUndo), "old undo cannot restore or replace a later removal")
        try expect(undoLibrary.undoReadLaterRemoval(latestUndo) && !undoLibrary.isReadLater(11), "undo restores only the last removed item")
        undoLibrary.removeReadLater(12)
        let readdedUndo = undoLibrary.readLaterUndo!.id
        undoLibrary.addReadLater(topicID: 12, title: "后来重新加入的内容", boardID: 414)
        try expect(!undoLibrary.undoReadLaterRemoval(readdedUndo) && undoLibrary.readLater.first?.title == "后来重新加入的内容", "undo never overwrites a later re-add")
        undoLibrary.removeReadLater(12)
        let clearingUndo = undoLibrary.readLaterUndo!.id
        undoLibrary.clearReadLater()
        try expect(!undoLibrary.undoReadLaterRemoval(clearingUndo) && undoLibrary.readLater.isEmpty, "clear invalidates pending undo")
        undoLibrary.addReadLater(topicID: 10, title: "当前账号主题", boardID: 12)
        undoLibrary.removeReadLater(10)
        let oldAccountUndo = undoLibrary.readLaterUndo!.id
        undoLibrary.setAccount(95)
        try expect(!undoLibrary.undoReadLaterRemoval(oldAccountUndo) && undoLibrary.readLater.isEmpty, "undo cannot cross accounts")
        undoLibrary.setAccount(94)
        try expect(undoLibrary.readLaterUndo == nil, "returning to account does not revive transient undo")
        undoLibrary.addReadLater(topicID: 10, title: "普通撤销期限", boardID: 12)
        undoLibrary.removeReadLater(10)
        let expiringUndo = undoLibrary.readLaterUndo!
        try expect(!undoLibrary.undoReadLaterRemoval(expiringUndo.id, now: expiringUndo.expiresAt!.addingTimeInterval(1)), "expired undo does not restore stale items")
        undoLibrary.addReadLater(topicID: 10, title: "读屏撤销期限", boardID: 12)
        undoLibrary.removeReadLater(10)
        let accessibleUndo = undoLibrary.readLaterUndo!.id
        undoLibrary.keepReadLaterUndoAvailable(accessibleUndo)
        try expect(undoLibrary.undoReadLaterRemoval(accessibleUndo, now: Date().addingTimeInterval(3600)), "accessibility undo remains available until dismissed")
        let importableLater = try undoLibrary.exportBackup(mode: .readLater)
        undoLibrary.removeReadLater(10)
        let importedUndo = undoLibrary.readLaterUndo!.id
        let importUndoPreview = try undoLibrary.previewImport(importableLater, mode: .readLater)
        try expect(undoLibrary.importBackup(importUndoPreview) && !undoLibrary.undoReadLaterRemoval(importedUndo), "imported same-ID entry invalidates stale undo")
        var failUndoWrite = false
        let undoFailure = NativeLibrary(accountID: 96, directory: dir, writeData: { data, url in
            if failUndoWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        undoFailure.addReadLater(topicID: 10, title: "可重试撤销", boardID: 12)
        undoFailure.removeReadLater(10)
        let failedUndo = undoFailure.readLaterUndo!.id
        failUndoWrite = true
        try expect(!undoFailure.undoReadLaterRemoval(failedUndo) && !undoFailure.isReadLater(10) && undoFailure.lastSaveError != nil, "undo write failure does not claim restoration")
        failUndoWrite = false
        try expect(undoFailure.undoReadLaterRemoval(failedUndo) && undoFailure.isReadLater(10), "failed undo can retry without duplicate restoration")
        print("NativeLibraryHarness: \(checks) checks passed")
    }
}
#endif
