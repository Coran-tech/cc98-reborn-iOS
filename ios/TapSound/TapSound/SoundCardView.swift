import SwiftUI

struct SoundCardView: View {
    let sound: SoundItem
    let isActive: Bool
    let isMuted: Bool
    let onPlay: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onPlay) {
                cardContent
            }
            .buttonStyle(SoundCardPressStyle())
            .disabled(isMuted)

            Menu {
                Button {
                    onRename()
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.16), in: Circle())
                    .contentShape(Circle())
            }
            .padding(11)
            .accessibilityLabel("管理\(sound.title)")
        }
        .opacity(isMuted ? 0.55 : 1)
        .saturation(isMuted ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.22), value: isMuted)
        .scaleEffect(isActive && !reduceMotion ? 1.025 : 1)
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.7),
            value: isActive
        )
        .accessibilityElement(children: .contain)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: sound.style.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.white.opacity(0.16))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }

            Spacer(minLength: 10)

            Text(sound.title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background {
            ZStack {
                sound.style.gradient
                LinearGradient(
                    colors: [.clear, .black.opacity(0.24)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.20))
                .frame(width: 92, height: 92)
                .blur(radius: 32)
                .offset(x: 28, y: -38)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isActive ? 0.85 : 0.30),
                            .white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isActive ? 1.6 : 1
                )
        }
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.06))
            }
        }
        .shadow(
            color: sound.accentColor.opacity(isActive ? 0.5 : 0.14),
            radius: isActive ? 22 : 10,
            x: 0,
            y: isActive ? 12 : 7
        )
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 9)
        .accessibilityLabel(sound.title)
        .accessibilityHint(isMuted ? "当前已静音" : "播放音效")
        .accessibilityValue(isActive ? "正在播放" : "")
    }
}

private struct SoundCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(
                .spring(response: 0.26, dampingFraction: 0.62),
                value: configuration.isPressed
            )
    }
}

#Preview("Sound Card") {
    ZStack {
        Color(hex: 0x0B0F1A).ignoresSafeArea()
        SoundCardView(
            sound: .preview(title: "掌声", styleIndex: 8),
            isActive: false,
            isMuted: false,
            onPlay: {},
            onRename: {},
            onDelete: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}
