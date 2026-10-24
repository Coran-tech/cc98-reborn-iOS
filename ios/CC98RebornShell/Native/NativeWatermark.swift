import SwiftUI
import UIKit

struct WatermarkInstaller: UIViewRepresentable {
    let raw: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(raw: raw, from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.window?.isHidden = true
    }

    final class Coordinator {
        var window: UIWindow?

        func update(raw: String?, from view: UIView) {
            DispatchQueue.main.async {
                self.install(raw: raw, from: view, attempts: 0)
            }
        }

        private func install(raw: String?, from view: UIView, attempts: Int) {
            guard let code = NativeWatermarkOverlay.normalizedCode(raw) else {
                window?.isHidden = true
                return
            }
            guard let scene = view.window?.windowScene else {
                if attempts < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.install(raw: raw, from: view, attempts: attempts + 1)
                    }
                }
                return
            }

            if let window {
                window.isHidden = false
                (window.rootViewController as? UIHostingController<NativeWatermarkOverlay>)?.rootView =
                    NativeWatermarkOverlay(raw: code)
                return
            }

            let host = UIHostingController(rootView: NativeWatermarkOverlay(raw: code))
            host.view.backgroundColor = .clear
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.backgroundColor = .clear
            window.isUserInteractionEnabled = false
            window.rootViewController = host
            window.isHidden = false
            self.window = window
        }
    }
}

struct NativeWatermarkOverlay: View {
    let raw: String?

    static func normalizedCode(_ raw: String?) -> String? {
        let value = String((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        guard value.count == 8,
              value.range(of: "^[a-z0-9]{8}$", options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return value
    }

    private var code: String? { Self.normalizedCode(raw) }

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
