import SwiftUI
import UIKit

enum UBBEditorInsertion {
    static func insert(_ snippet: String, text: inout String, selection: inout NSRange) {
        let ns = text as NSString
        let range = clamped(selection, length: ns.length)
        text = ns.replacingCharacters(in: range, with: snippet)
        selection = NSRange(location: range.location + (snippet as NSString).length, length: 0)
    }

    static func wrap(_ prefix: String, _ suffix: String, text: inout String, selection: inout NSRange) {
        let ns = text as NSString
        let range = clamped(selection, length: ns.length)
        let selected = ns.substring(with: range)
        let replacement = prefix + selected + suffix
        text = ns.replacingCharacters(in: range, with: replacement)
        let cursor = selected.isEmpty
            ? range.location + (prefix as NSString).length
            : range.location + (replacement as NSString).length
        selection = NSRange(location: cursor, length: 0)
    }

    static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }
}

struct UBBTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var minHeight: CGFloat = 260

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .yes
        textView.text = text
        textView.selectedRange = clamped(selection, in: text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            let previous = textView.selectedRange
            textView.text = text
            textView.selectedRange = clamped(previous, in: text)
        }
        let next = clamped(selection, in: textView.text)
        if textView.selectedRange != next {
            textView.selectedRange = next
        }
    }

    private func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(0, range.location), length)
        let maxLength = length - location
        return NSRange(location: location, length: min(max(0, range.length), maxLength))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: UBBTextEditor

        init(parent: UBBTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.selection = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if parent.selection != textView.selectedRange {
                parent.selection = textView.selectedRange
            }
        }
    }
}
