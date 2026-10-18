import Foundation

final class LocalSettingsStore {
    private let file: URL
    private var values: [String: Any]
    static let byteLimit = 2 * 1024 * 1024

    init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= Self.byteLimit,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BridgeFailure(code: "STORAGE_CORRUPT", message: "本地设置无法读取；已保留原文件，未覆盖。")
            }
            values = object.filter { StoragePolicy.canWrite($0.key) && !StoragePolicy.containsSecret($0.value) }
        } else { values = [:] }
    }

    func get(_ keys: Any?) throws -> [String: Any] {
        if keys == nil || keys is NSNull { return values.filter { StoragePolicy.canRead($0.key) } }
        if let defaults = keys as? [String: Any] {
            try validate(Array(defaults.keys), write: false)
            guard defaults.allSatisfy({ !StoragePolicy.readOnly.contains($0.key) || $0.value is NSNull }) else {
                throw BridgeFailure(code: "PROTECTED_DEFAULT_DENIED", message: "只读绑定或服务状态不能由调用者提供默认摘要。")
            }
            return defaults.merging(values.filter { defaults[$0.key] != nil }) { _, stored in stored }
        }
        let selected = try keyList(keys)
        try validate(selected, write: false)
        return values.filter { selected.contains($0.key) }
    }

    func set(_ update: [String: Any]) throws -> [String: Any] {
        try validate(Array(update.keys), write: true)
        guard !StoragePolicy.containsSecret(update), JSONSerialization.isValidJSONObject(update) else {
            throw BridgeFailure(code: "SENSITIVE_STORAGE_DENIED", message: "验证壳不保存令牌、密码或 API 密钥。")
        }
        var next = values
        var changes: [String: Any] = [:]
        for (key, value) in update {
            var change: [String: Any] = ["newValue": value]
            if let old = values[key] { change["oldValue"] = old }
            changes[key] = change
            next[key] = value
        }
        try persist(next)
        return changes
    }

    func remove(_ keys: Any?) throws -> [String: Any] {
        let selected = try keyList(keys)
        try validate(selected, write: true)
        var next = values
        var changes: [String: Any] = [:]
        for key in selected {
            if let old = next.removeValue(forKey: key) { changes[key] = ["oldValue": old] }
        }
        try persist(next)
        return changes
    }

    private func keyList(_ keys: Any?) throws -> [String] {
        if let key = keys as? String { return [key] }
        if let array = keys as? [String], array.count <= 500 { return array }
        throw BridgeFailure(code: "INVALID_ARGUMENT", message: "存储键必须是字符串或字符串数组。")
    }

    private func validate(_ keys: [String], write: Bool) throws {
        guard keys.count <= 500, keys.allSatisfy({ $0.count <= 180 && (write ? StoragePolicy.canWrite($0) : StoragePolicy.canRead($0)) }) else {
            throw BridgeFailure(code: "STORAGE_KEY_DENIED", message: "该存储键不在验证壳允许范围内；绑定记录不能由网页写入。")
        }
    }

    private func persist(_ next: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        guard data.count <= Self.byteLimit else { throw BridgeFailure(code: "STORAGE_QUOTA", message: "本地增强设置超过 2 MiB 限额。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        values = next
    }
}
