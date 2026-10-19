import SwiftUI

struct NativeWatermarkOverlay: View {
    let raw: String?

    private var code: String? {
        let value = String((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        guard value.count == 8,
              value.range(of: "^[a-z0-9]{8}$", options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return value
    }

    var body: some View {
        if let code {
            Canvas { context, size in
                var layer = context
                layer.translateBy(x: size.width / 2, y: size.height / 2)
                layer.rotate(by: .degrees(-25))
                layer.translateBy(x: -size.width / 2, y: -size.height / 2)
                let text = layer.resolve(
                    Text(code)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gray.opacity(0.05))
                )
                let limit = max(size.width, size.height) * 1.5
                for y in stride(from: -limit, through: limit * 1.5, by: 128) {
                    for x in stride(from: -limit, through: limit * 1.5, by: 192) {
                        layer.draw(text, at: CGPoint(x: x, y: y))
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
