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

        if selected.isEmpty {
            // Empty block: leave the caret between the opening and closing tags.
            selection = NSRange(location: range.location + (prefix as NSString).length, length: 0)
        } else {
            // Applied to existing text: select the whole processed segment.
            selection = NSRange(location: range.location, length: (replacement as NSString).length)
        }
    }

    static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }
}

struct UBBTextEditor: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var text: String
    @Binding var selection: NSRange
    let controller: UBBEditorController
    var minHeight: CGFloat = 260

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        updateFont(of: textView)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.isScrollEnabled = false
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .yes
        textView.text = text
        textView.selectedRange = clamped(selection, in: text)
        controller.attach(textView, text: $text, selection: $selection)
        context.coordinator.installKeyboardToolbar(on: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.attach(textView, text: $text, selection: $selection)
        updateFont(of: textView)
        context.coordinator.updateKeyboardToolbar(for: textView)
        // A SwiftUI refresh must not replace the IME's unfinished composition.
        guard textView.markedTextRange == nil else { return }
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let contentHeight = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(minHeight, contentHeight))
    }

    private func updateFont(of textView: UITextView) {
        // UIKit's global preferred size does not include a SwiftUI environment
        // override. Use the same category as the surrounding editor controls.
        let category = UIContentSizeCategory(dynamicTypeSize)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        if textView.font != font { textView.font = font }
    }

    private func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(0, range.location), length)
        let maxLength = length - location
        return NSRange(location: location, length: min(max(0, range.length), maxLength))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: UBBTextEditor
        private var keyboardToolbar: UIToolbar?
        private var dismissKeyboardItem: UIBarButtonItem?
        private var configuredToolbarFont: UIFont?
        private var configuredToolbarHeight: CGFloat?

        init(parent: UBBTextEditor) {
            self.parent = parent
        }

        func installKeyboardToolbar(on textView: UITextView) {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            toolbar.autoresizingMask = [.flexibleWidth]
            let button = UIBarButtonItem(title: "收起键盘", style: .done,
                                         target: self, action: #selector(dismissKeyboard))
            button.accessibilityIdentifier = "compose.dismissKeyboard"
            toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), button]
            keyboardToolbar = toolbar
            dismissKeyboardItem = button
            configuredToolbarFont = nil
            configuredToolbarHeight = nil
            updateKeyboardToolbar(for: textView)
            textView.inputAccessoryView = toolbar
        }

        func updateKeyboardToolbar(for textView: UITextView) {
            guard let toolbar = keyboardToolbar, let font = textView.font else { return }
            let height = max(44, ceil(font.lineHeight) + 16)
            toolbar.tintColor = UIColor(ShellTheme.accent)
            if configuredToolbarFont != font {
                configuredToolbarFont = font
                dismissKeyboardItem?.setTitleTextAttributes([.font: font], for: .normal)
            }
            // UIKit owns the laid-out frame. It is not a configuration marker:
            // typing can update SwiftUI while the keyboard adjusts that frame.
            // Reload only for a genuinely changed target height, never per key.
            if configuredToolbarHeight != height {
                configuredToolbarHeight = height
                toolbar.frame.size.height = height
                if textView.isFirstResponder { textView.reloadInputViews() }
            }
        }

        @objc private func dismissKeyboard() {
            parent.controller.dismissKeyboard()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.selection = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.noteSelection(textView.selectedRange)
            if parent.selection != textView.selectedRange {
                parent.selection = textView.selectedRange
            }
        }
    }
}
