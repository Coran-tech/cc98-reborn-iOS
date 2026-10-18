import XCTest
@testable import CC98RebornShell

final class LocalSettingsStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    private func store() throws -> LocalSettingsStore { try LocalSettingsStore(file: directory.appendingPathComponent("settings.json")) }

    func testDefaultsPersistenceAndChromeChangeShape() throws {
        let first = try store()
        let key = "cc98ComfortSettings"
        XCTAssertEqual(try first.get([key: ["enabled": true]])[key] as? [String: Bool], ["enabled": true])
        let changes = try first.set([key: ["enabled": false]])
        XCTAssertNotNil((changes[key] as? [String: Any])?["newValue"])
        let reloaded = try store()
        XCTAssertEqual(try reloaded.get(key)[key] as? [String: Bool], ["enabled": false])
        let removed = try reloaded.remove([key])
        XCTAssertNotNil((removed[key] as? [String: Any])?["oldValue"])
        XCTAssertTrue(try reloaded.get(nil).isEmpty)
    }
    func testBindingCannotBeForgedOrRemovedViaGenericStorage() throws {
        let subject = try store()
        XCTAssertThrowsError(try subject.set([ShellPolicy.bindingKey: ["bound": true]]))
        XCTAssertThrowsError(try subject.remove(ShellPolicy.bindingKey))
        XCTAssertThrowsError(try subject.get([ShellPolicy.bindingKey: ["bound": true]]))
        XCTAssertTrue(try subject.get(ShellPolicy.bindingKey).isEmpty)
    }
    func testRejectedWritesDoNotMutateExistingValues() throws {
        let subject = try store()
        _ = try subject.set(["cc98ComfortSettings": ["enabled": true]])
        XCTAssertThrowsError(try subject.set(["cc98ComfortSettings": ["apiKey": "private"]]))
        XCTAssertEqual(try subject.get("cc98ComfortSettings")["cc98ComfortSettings"] as? [String: Bool], ["enabled": true])
    }
    func testCorruptExistingFileIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        let original = Data("not json".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try store())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
