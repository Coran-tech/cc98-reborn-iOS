import SwiftUI
import UIKit

@MainActor
final class UBBEditorController: ObservableObject {
    private weak var textView: UITextView?
    private var textBinding: Binding<String>?
    private var selectionBinding: Binding<NSRange>?
    private var lastSelection = NSRange(location: 0, length: 0)
    private var pendingSelection: NSRange?
    private var pendingWorkItem: DispatchWorkItem?

    func attach(_ textView: UITextView, text: Binding<String>, selection: Binding<NSRange>) {
        self.textView = textView
        self.textBinding = text
        self.selectionBinding = selection
        if textView.isFirstResponder {
            lastSelection = textView.selectedRange
        }
    }

    func noteSelection(_ range: NSRange) {
        if pendingSelection != nil { return }
        guard textView?.isFirstResponder == true else { return }
        lastSelection = range
    }

    @discardableResult
    func insert(_ snippet: String) -> Bool {
        guard let textView else { return false }
        let ns = textView.text as NSString
        let range = UBBEditorInsertion.clamped(
            textView.isFirstResponder ? textView.selectedRange : lastSelection,
            length: ns.length
        )
        textView.text = ns.replacingCharacters(in: range, with: snippet)
        let nextSelection = NSRange(
            location: range.location + (snippet as NSString).length,
            length: 0
        )
        textView.selectedRange = nextSelection
        lastSelection = nextSelection
        pendingSelection = nextSelection
        textBinding?.wrappedValue = textView.text
        selectionBinding?.wrappedValue = nextSelection
        schedulePendingSelection()
        return true
    }

    private func schedulePendingSelection() {
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyPendingSelection()
        }
        pendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func applyPendingSelection() {
        guard let textView, let pendingSelection else { return }
        textView.selectedRange = pendingSelection
        textView.becomeFirstResponder()
        selectionBinding?.wrappedValue = pendingSelection
        lastSelection = pendingSelection
        self.pendingSelection = nil
    }

    @discardableResult
    func wrap(_ prefix: String, _ suffix: String) -> Bool {
        guard let textView else { return false }
        let ns = textView.text as NSString
        let range = UBBEditorInsertion.clamped(
            textView.isFirstResponder ? textView.selectedRange : lastSelection,
            length: ns.length
        )
        let selected = ns.substring(with: range)
        let replacement = prefix + selected + suffix
        textView.text = ns.replacingCharacters(in: range, with: replacement)

        let nextSelection: NSRange
        if selected.isEmpty {
            nextSelection = NSRange(
                location: range.location + (prefix as NSString).length,
                length: 0
            )
        } else {
            nextSelection = NSRange(
                location: range.location,
                length: (replacement as NSString).length
            )
        }
        textView.selectedRange = nextSelection
        textView.becomeFirstResponder()
        lastSelection = nextSelection
        textBinding?.wrappedValue = textView.text
        selectionBinding?.wrappedValue = nextSelection
        return true
    }
}
