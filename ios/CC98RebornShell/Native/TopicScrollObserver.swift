import SwiftUI
import UIKit

/// Finds the enclosing UIScrollView and reports upward overscroll past the
/// content bottom. SwiftUI's ScrollView does not expose an iOS 17 equivalent
/// of onScrollGeometryChange, and simultaneous DragGestures are swallowed by
/// the scroll view, so observe the underlying UIScrollView directly.
struct ScrollBottomObserver: UIViewRepresentable {
    let threshold: CGFloat
    let onOverscroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(threshold: threshold, onOverscroll: onOverscroll)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.threshold = threshold
        context.coordinator.onOverscroll = onOverscroll
        DispatchQueue.main.async {
            context.coordinator.attach(from: uiView)
        }
    }

    final class Coordinator {
        var threshold: CGFloat
        var onOverscroll: () -> Void
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var fired = false

        init(threshold: CGFloat, onOverscroll: @escaping () -> Void) {
            self.threshold = threshold
            self.onOverscroll = onOverscroll
        }

        func attach(from view: UIView) {
            if let scrollView, view.isDescendant(of: scrollView) { return }
            var node: UIView? = view.superview
            while let current = node {
                if let scrollView = current as? UIScrollView {
                    bind(scrollView)
                    return
                }
                node = current.superview
            }
        }

        private func bind(_ scrollView: UIScrollView) {
            self.scrollView = scrollView
            fired = false
            observations = []
            observations.append(scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.check()
            })
            observations.append(scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.check()
            })
            observations.append(scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                self?.check()
            })
            check()
        }

        private func check() {
            guard let scrollView,
                  scrollView.bounds.height > 0,
                  scrollView.contentSize.height > scrollView.bounds.height + 1 else {
                return
            }
            let maxOffset = scrollView.contentSize.height
                + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
            let overscroll = scrollView.contentOffset.y - maxOffset
            if overscroll > threshold, !fired {
                fired = true
                onOverscroll()
            } else if overscroll < 8 {
                fired = false
            }
        }
    }
}
