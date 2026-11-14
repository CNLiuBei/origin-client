import SwiftUI

/// 密码 / Token 输入框。
/// macOS 上 SwiftUI 的 SecureField 底层是普通文本框：不开启安全输入、不限制输入法，
/// 在中文输入法下小写 u 等键会被输入法吞掉。这里改用系统的 NSSecureTextField，
/// 它会开启安全输入并只允许英文输入源。
struct PasswordField: View {
    let title: String
    @Binding var text: String
    var identifier: String?
    var prompt: String?
    /// 在输入框右侧放一个眼睛按钮，用来临时显示密码
    var canReveal: Bool = false
    /// 仅 macOS 使用：与外部焦点状态同步
    var isFocused: Binding<Bool>?
    var onSubmit: () -> Void = {}

    @State private var revealed = false

    var body: some View {
        #if os(macOS)
        LabeledContent(title) {
            HStack(spacing: 6) {
                if revealed {
                    TextField("", text: $text, prompt: prompt.map { Text($0) })
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(onSubmit)
                } else {
                    SecureTextField(text: $text, identifier: identifier, prompt: prompt, isFocused: isFocused, onSubmit: onSubmit)
                }
                if canReveal {
                    revealButton
                }
            }
        }
        #else
        HStack {
            Group {
                if revealed {
                    TextField(title, text: $text, prompt: prompt.map { Text($0) })
                } else {
                    SecureField(title, text: $text, prompt: prompt.map { Text($0) })
                }
            }
            .textContentType(.password)
            .accessibilityIdentifier(identifier ?? "")
            .onSubmit(onSubmit)
            if canReveal {
                revealButton
            }
        }
        #endif
    }

    private var revealButton: some View {
        Button {
            revealed.toggle()
        } label: {
            Image(systemName: revealed ? "eye.slash" : "eye")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .accessibilityLabel(revealed ? "隐藏密码" : "显示密码")
    }
}

#if os(macOS)
private struct SecureTextField: NSViewRepresentable {
    @Binding var text: String
    let identifier: String?
    let prompt: String?
    let isFocused: Binding<Bool>?
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.contentType = .password
        field.placeholderString = prompt
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingHead
        field.delegate = context.coordinator
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != prompt { field.placeholderString = prompt }
        if field.stringValue != text { field.stringValue = text }
        if isFocused?.wrappedValue == true, field.currentEditor() == nil {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SecureTextField

        init(parent: SecureTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_: Notification) {
            if parent.isFocused?.wrappedValue == false { parent.isFocused?.wrappedValue = true }
        }

        func controlTextDidEndEditing(_: Notification) {
            if parent.isFocused?.wrappedValue == true { parent.isFocused?.wrappedValue = false }
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
#endif
