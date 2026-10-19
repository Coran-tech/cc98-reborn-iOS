import Foundation
import UserNotifications
import SwiftUI

@MainActor
final class NativeNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var openMessages = false

    private var api: CC98API?
    private var auth: NativeAuth?
    private var pollTask: Task<Void, Never>?
    private var lastCounts: NativeMessageCounts?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func configure(auth: NativeAuth, api: CC98API) {
        self.auth = auth
        self.api = api
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            start()
        }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func markMessagesOpened() {
        openMessages = false
    }

    private func poll() async {
        guard let api, auth?.profile != nil else { return }
        guard let counts = try? await api.messageCounts() else { return }

        if let lastCounts {
            postIfIncreased(lastCounts.replyCount, counts.replyCount, title: "新回复", identifier: "reply")
            postIfIncreased(lastCounts.atCount, counts.atCount, title: "新的 @", identifier: "at")
            postIfIncreased(lastCounts.systemCount, counts.systemCount, title: "系统消息", identifier: "system")
            postIfIncreased(lastCounts.messageCount, counts.messageCount, title: "新私信", identifier: "message")
        }
        lastCounts = counts
    }

    private func postIfIncreased(_ old: Int?, _ new: Int?, title: String, identifier: String) {
        let previous = old ?? 0
        let current = new ?? 0
        guard current > previous else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "你有 \(current - previous) 条新消息"
        content.sound = .default
        content.threadIdentifier = "cc98.\(identifier)"
        content.userInfo = ["tab": "messages"]
        let request = UNNotificationRequest(
            identifier: "cc98.\(identifier).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            openMessages = true
            completionHandler()
        }
    }
}
