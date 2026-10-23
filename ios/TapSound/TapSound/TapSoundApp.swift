import SwiftUI

@main
struct TapSoundApp: App {
    @StateObject private var store = SoundBoardStore()

    var body: some Scene {
        WindowGroup {
            SoundBoardView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
