import AppKit
import SwiftUI

final class PasteAwareTextField: NSTextField {
    var onTextChange: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            if let pasted = NSPasteboard.general.string(forType: .string) {
                if let editor = currentEditor() {
                    editor.insertText(pasted)
                    stringValue = editor.string
                } else {
                    stringValue = pasted
                }
                onTextChange?(stringValue)
                return true
            }
            return false
        case "a":
            currentEditor()?.selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

struct PasteFriendlyTokenField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> PasteAwareTextField {
        let field = PasteAwareTextField(frame: .zero)
        field.delegate = context.coordinator
        field.onTextChange = { value in
            context.coordinator.updateText(value)
        }
        field.isBezeled = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        field.textColor = NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.12, alpha: 1.0)
        field.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.985, blue: 0.965, alpha: 0.9)
        field.drawsBackground = true
        return field
    }

    func updateNSView(_ nsView: PasteAwareTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled
        nsView.textColor = isEnabled
            ? NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.12, alpha: 1.0)
            : NSColor(calibratedRed: 0.46, green: 0.43, blue: 0.39, alpha: 1.0)
        nsView.backgroundColor = isEnabled
            ? NSColor(calibratedRed: 1.0, green: 0.985, blue: 0.965, alpha: 0.9)
            : NSColor(calibratedRed: 0.97, green: 0.955, blue: 0.935, alpha: 0.72)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func updateText(_ value: String) {
            text = value
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}
