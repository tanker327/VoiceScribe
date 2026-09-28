import SwiftUI
import AppKit

/// The transcript editor. It wraps `NSTextView` directly instead of SwiftUI's `TextEditor` so the
/// text can be read-only yet still selectable, scrollable and copyable, and so a double-click can
/// be told apart from a single click.
///
/// The text starts read-only. A double-click flips `isEditing` and puts the caret where the user
/// clicked; the caret is the cue that typing now works. `isEditing` goes back to false as soon as
/// the text view stops being first responder: Escape (handled by `ContentView`'s key monitor),
/// a click elsewhere, or the view being swapped out.
struct TranscriptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    /// False while recording: the text stays read-only and a double-click does nothing.
    var isEnabled: Bool
    var fontSize: CGFloat

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // The class method instantiates the receiver, so the document view is a TranscriptTextView.
        let scrollView = TranscriptTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? TranscriptTextView else {
            preconditionFailure("scrollableTextView() did not create a TranscriptTextView")
        }
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isRichText = false          // pasted text drops its fonts and colors
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes[.paragraphStyle] = Self.paragraphStyle

        let coordinator = context.coordinator
        textView.onDoubleClick = { [weak coordinator] textView in
            coordinator?.beginEditing(in: textView) ?? false
        }
        textView.onResignFirstResponder = { [weak coordinator] textView in
            coordinator?.editingEnded(in: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TranscriptTextView else { return }
        context.coordinator.parent = self

        let font = NSFont.systemFont(ofSize: fontSize)
        if textView.font != font {
            textView.font = font   // plain-text view: restyles all text and future typing
        }

        if textView.string != text {
            // A programmatic replacement (transcription landed, history loaded, Clear). Typing
            // never gets here because textDidChange already wrote the same string back.
            textView.string = text
            if let storage = textView.textStorage {
                storage.setAttributes(textView.typingAttributes,
                                      range: NSRange(location: 0, length: storage.length))
            }
            // The old undo actions refer to text that no longer exists.
            context.coordinator.undoManager.removeAllActions()
        }

        textView.isEditable = isEditing && isEnabled
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptEditor
        /// The editor's own undo stack, so a programmatic text replacement can drop it without
        /// touching the window's other fields.
        let undoManager = UndoManager()

        init(_ parent: TranscriptEditor) {
            self.parent = parent
        }

        /// A double-click on the read-only text. Returns whether editing was enabled.
        func beginEditing(in textView: TranscriptTextView) -> Bool {
            guard parent.isEnabled else { return false }
            // Now rather than on the next SwiftUI update, so this very click already edits.
            textView.isEditable = true
            parent.isEditing = true
            return true
        }

        func editingEnded(in textView: TranscriptTextView) {
            // Deferred: the text view can resign while SwiftUI is mid-update (being swapped out),
            // and state must not change during a view update.
            Task {
                guard parent.isEditing, textView.window?.firstResponder !== textView else { return }
                parent.isEditing = false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }
    }
}

/// `NSTextView` that reports a double-click while read-only and the loss of first responder.
final class TranscriptTextView: NSTextView {
    /// Double-click while read-only. Return true once editing is enabled; the caret then goes
    /// to the click instead of the double-click's usual word selection.
    var onDoubleClick: ((TranscriptTextView) -> Bool)?
    var onResignFirstResponder: ((TranscriptTextView) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if !isEditable, event.clickCount == 2, onDoubleClick?(self) == true {
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onResignFirstResponder?(self)
        }
        return resigned
    }
}
