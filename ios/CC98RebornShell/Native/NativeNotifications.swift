import Foundation
import UserNotifications
import SwiftUI

@MainActor
final class NativeNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var openMessages = false
    @Published var notice: String?

    private var api: CC98API?
    private var auth: NativeAuth?
    private var pollTask: Task<Void, Never>?
    private var lastCounts: NativeMessageCounts?
    private var lastAccountID: Int?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func configure(auth: NativeAuth, api: CC98API) {
        self.auth = auth
        self.api = api
        start()
    }

    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else { stop(); return false }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if allowed { start(); return true }
            notice = "系统通知尚未允许。你仍可在“消息”查看新内容，也可以在系统设置中开启通知。"
        } catch {
            notice = "暂时无法启用通知，请稍后重试。消息页面仍可正常使用。"
        }
        stop()
        return false
    }

    func start() {
        #if DEBUG
        if NativeUITestFixture.isEnabled { return }
        #endif
        guard UserDefaults.standard.bool(forKey: "native.notificationsEnabled") else { return }
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
        guard let api, let accountID = auth?.profile?.id else { return }
        let accountContext = auth?.captureAccountContext()
        if lastAccountID != accountID {
            lastAccountID = accountID
            lastCounts = nil
        }
        guard let counts = try? await api.messageCounts() else { return }
        guard auth?.captureAccountContext() == accountContext,
              auth?.profile?.id == accountID else { return }

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
        content.userInfo = ["tab": "messages", "accountID": lastAccountID ?? 0]
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
            let expectedID = response.notification.request.content.userInfo["accountID"] as? Int
            if let expectedID, expectedID != auth?.activeAccountID {
                notice = "这条通知来自另一个账号。请先在“我的”切换到对应账号，再查看消息。"
            } else {
                openMessages = true
            }
            completionHandler()
        }
    }
}
