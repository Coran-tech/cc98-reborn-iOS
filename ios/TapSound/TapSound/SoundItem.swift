import SwiftUI

struct SoundStyle {
    let symbolName: String
    let primaryHex: UInt32
    let secondaryHex: UInt32

    var accentColor: Color { Color(hex: primaryHex) }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: primaryHex), Color(hex: secondaryHex)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let palette: [SoundStyle] = [
        SoundStyle(symbolName: "waveform", primaryHex: 0x22D3EE, secondaryHex: 0x2563EB),
        SoundStyle(symbolName: "bell.fill", primaryHex: 0xFBBF24, secondaryHex: 0xD97706),
        SoundStyle(symbolName: "sparkles", primaryHex: 0xC084FC, secondaryHex: 0x7C3AED),
        SoundStyle(symbolName: "bolt.fill", primaryHex: 0xFB7185, secondaryHex: 0xBE123C),
        SoundStyle(symbolName: "music.note", primaryHex: 0x86EFAC, secondaryHex: 0x15803D),
        SoundStyle(symbolName: "bubble.left.fill", primaryHex: 0x7DD3FC, secondaryHex: 0x0369A1),
        SoundStyle(symbolName: "camera.fill", primaryHex: 0x94A3B8, secondaryHex: 0x334155),
        SoundStyle(symbolName: "flame.fill", primaryHex: 0xFB923C, secondaryHex: 0xB91C1C),
        SoundStyle(symbolName: "leaf.fill", primaryHex: 0x5EEAD4, secondaryHex: 0x0F766E),
        SoundStyle(symbolName: "moon.stars.fill", primaryHex: 0xF0ABFC, secondaryHex: 0x6D28D9)
    ]
}

struct SoundItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let fileName: String
    let styleIndex: Int
    let createdAt: Date

    var style: SoundStyle {
        let count = SoundStyle.palette.count
        let index = ((styleIndex % count) + count) % count
        return SoundStyle.palette[index]
    }

    var accentColor: Color { style.accentColor }
}

extension SoundItem {
    static func preview(title: String, styleIndex: Int) -> SoundItem {
        SoundItem(
            id: UUID(),
            title: title,
            fileName: "preview.m4a",
            styleIndex: styleIndex,
            createdAt: Date()
        )
    }
}
