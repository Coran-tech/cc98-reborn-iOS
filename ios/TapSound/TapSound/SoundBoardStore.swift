import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum SoundImportError: LocalizedError {
    case invalidLink
    case insecureLink
    case downloadFailed(String)
    case notAudio
    case fileTooLarge
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "链接格式不正确"
        case .insecureLink:
            return "请使用 HTTPS 链接"
        case .downloadFailed(let detail):
            return detail.isEmpty ? "下载失败" : "下载失败：\(detail)"
        case .notAudio:
            return "这不是可播放的音频文件"
        case .fileTooLarge:
            return "音频超过 60 MB"
        case .saveFailed:
            return "无法保存音频"
        }
    }
}

@MainActor
final class SoundBoardStore: ObservableObject {
    @Published private(set) var sounds: [SoundItem] = []
    @Published private(set) var activeSoundID: UUID?
    @Published private(set) var isImporting = false

    @Published var isMuted = false {
        didSet {
            if isMuted {
                stopAll()
            }
        }
    }

    var activeSound: SoundItem? {
        guard let activeSoundID else { return nil }
        return sounds.first { $0.id == activeSoundID }
    }

    private let fileManager = FileManager.default
    private let libraryURL: URL
    private let audioDirectory: URL
    private let urlSession: URLSession
    private let maxImportBytes = 60 * 1024 * 1024
    private let haptics = UIImpactFeedbackGenerator(style: .soft)

    private var players: [UUID: AVAudioPlayer] = [:]
    private var finishTask: Task<Void, Never>?
    private var categoryConfigured = false

    init() {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let rootURL = baseURL.appendingPathComponent("TapSound", isDirectory: true)
        audioDirectory = rootURL.appendingPathComponent("Audio", isDirectory: true)
        libraryURL = rootURL.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        urlSession = URLSession(configuration: configuration)

        configureAudioSessionCategory()
        loadLibrary()
        haptics.prepare()
    }

    // MARK: - Playback

    func play(_ sound: SoundItem) {
        guard !isMuted else { return }

        if players[sound.id] == nil {
            preloadPlayer(for: sound)
        }
        guard let player = players[sound.id] else { return }

        activateAudioSession()

        finishTask?.cancel()
        players.values.forEach { $0.stop() }
        player.currentTime = 0
        player.play()

        activeSoundID = sound.id
        haptics.impactOccurred(intensity: 0.65)
        haptics.prepare()
        scheduleFinish(for: sound, after: player.duration)
    }

    func stopAll() {
        finishTask?.cancel()
        finishTask = nil
        players.values.forEach { $0.stop() }
        activeSoundID = nil
    }

    func toggleMute() {
        isMuted.toggle()
        haptics.impactOccurred(intensity: 0.5)
        haptics.prepare()
    }

    // MARK: - Library management

    func rename(_ sound: SoundItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = sounds.firstIndex(where: { $0.id == sound.id }) else { return }

        sounds[index].title = String(trimmed.prefix(30))
        saveLibrary()
    }

    func delete(_ sound: SoundItem) {
        if activeSoundID == sound.id {
            stopAll()
        }

        players[sound.id]?.stop()
        players.removeValue(forKey: sound.id)
        try? fileManager.removeItem(at: audioURL(for: sound))
        sounds.removeAll { $0.id == sound.id }
        saveLibrary()
    }

    // MARK: - Imports

    /// Imports files picked from the Files app. Returns a short error summary, if any.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> String? {
        guard !urls.isEmpty else { return nil }

        isImporting = true
        defer { isImporting = false }

        var failures = 0
        var firstError: String?

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let item = try addSound(
                    copying: url,
                    title: displayTitle(for: url),
                    fileExtension: audioFileExtension(for: url)
                )
                sounds.append(item)
                saveLibrary()
            } catch {
                failures += 1
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }

        guard failures > 0 else { return nil }
        return urls.count == 1 ? firstError : "\(failures) 个文件未能导入"
    }

    /// Downloads an audio file from an HTTPS URL and adds it to the board.
    @discardableResult
    func importRemoteSound(from rawLink: String) async throws -> SoundItem {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
            throw SoundImportError.invalidLink
        }
        guard scheme == "https" else {
            throw SoundImportError.insecureLink
        }

        isImporting = true
        defer { isImporting = false }

        do {
            let (temporaryURL, response) = try await urlSession.download(from: url)

            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw SoundImportError.downloadFailed("HTTP \(http.statusCode)")
            }

            let extensionName = audioFileExtension(for: url, mimeType: response.mimeType)
            let item = try addSound(
                copying: temporaryURL,
                title: displayTitle(for: url),
                fileExtension: extensionName
            )
            sounds.append(item)
            saveLibrary()
            return item
        } catch let error as SoundImportError {
            throw error
        } catch {
            throw SoundImportError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - File helpers

    private func audioURL(for sound: SoundItem) -> URL {
        audioDirectory.appendingPathComponent(sound.fileName)
    }

    @discardableResult
    private func addSound(
        copying sourceURL: URL,
        title: String,
        fileExtension: String
    ) throws -> SoundItem {
        let sourceSize = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let sourceSize, sourceSize > maxImportBytes {
            throw SoundImportError.fileTooLarge
        }

        let id = UUID()
        let safeExtension = fileExtension.isEmpty ? "m4a" : fileExtension
        let fileName = "\(id.uuidString.lowercased()).\(safeExtension)"
        let destinationURL = audioDirectory.appendingPathComponent(fileName)

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw SoundImportError.saveFailed
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw SoundImportError.notAudio
        }

        guard player.duration > 0.05 else {
            try? fileManager.removeItem(at: destinationURL)
            throw SoundImportError.notAudio
        }

        player.volume = 0.9
        player.prepareToPlay()
        players[id] = player

        return SoundItem(
            id: id,
            title: title,
            fileName: fileName,
            styleIndex: sounds.count,
            createdAt: Date()
        )
    }

    private func displayTitle(for url: URL) -> String {
        let rawName = url.deletingPathExtension().lastPathComponent
        let decoded = rawName.removingPercentEncoding ?? rawName
        let cleaned = decoded
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fallback = cleaned.isEmpty ? (url.host ?? "未命名音效") : cleaned
        return String(fallback.prefix(30))
    }

    private func audioFileExtension(for url: URL, mimeType: String? = nil) -> String {
        let knownExtensions: Set<String> = [
            "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "caf", "mp4", "m4b", "flac"
        ]
        let pathExtension = url.pathExtension.lowercased()
        if knownExtensions.contains(pathExtension) {
            return pathExtension
        }

        if !pathExtension.isEmpty,
           UTType(filenameExtension: pathExtension)?.conforms(to: .audio) == true {
            return pathExtension
        }

        if let mimeType,
           let type = UTType(mimeType: mimeType),
           type.conforms(to: .audio),
           let preferred = type.preferredFilenameExtension {
            return preferred
        }

        return "m4a"
    }

    private func preloadPlayer(for sound: SoundItem) {
        let url = audioURL(for: sound)
        guard fileManager.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }

        player.volume = 0.9
        player.prepareToPlay()
        players[sound.id] = player
    }

    private func scheduleFinish(for sound: SoundItem, after duration: TimeInterval) {
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.08))
            guard !Task.isCancelled, let self else { return }
            guard self.activeSoundID == sound.id else { return }

            withAnimation(.easeOut(duration: 0.22)) {
                self.activeSoundID = nil
            }
        }
    }

    // MARK: - Persistence

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              let decoded = try? JSONDecoder().decode([SoundItem].self, from: data) else {
            return
        }

        let existing = decoded.filter {
            fileManager.fileExists(atPath: audioURL(for: $0).path)
        }
        sounds = existing.sorted { $0.createdAt < $1.createdAt }
        if existing.count != decoded.count {
            saveLibrary()
        }
        for sound in sounds {
            preloadPlayer(for: sound)
        }
    }

    private func saveLibrary() {
        do {
            let data = try JSONEncoder().encode(sounds)
            try data.write(to: libraryURL, options: .atomic)
        } catch {
            print("Could not save sound library: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio session

    private func configureAudioSessionCategory() {
        guard !categoryConfigured else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            categoryConfigured = true
        } catch {
            print("Audio session category could not be configured: \(error.localizedDescription)")
        }
    }

    private func activateAudioSession() {
        configureAudioSessionCategory()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session could not be activated: \(error.localizedDescription)")
        }
    }
}
