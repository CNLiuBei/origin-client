#if DEBUG
import AppKit

/// 进程内无障碍树中的一个元素
struct UINode {
    let element: NSAccessibilityProtocol
    let role: String
    let label: String
    let value: String
    let identifier: String
    let frame: CGRect
    let depth: Int

    private static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .textArea, .slider,
        .row, .cell, .link, .tabGroup, .comboBox, .incrementor, .disclosureTriangle, .image, .staticText,
    ]

    /// SwiftUI 只在有辅助功能客户端时才生成内容的无障碍树，这里以客户端身份访问一次自己来激活
    private static let activateAccessibility: Void = {
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
    }()

    /// 深度优先遍历窗口；默认只保留可交互或带文字的元素
    static func collect(in window: NSWindow, includeAll: Bool, limit: Int = 4000) -> [UINode] {
        _ = activateAccessibility
        var result: [UINode] = []
        func walk(_ object: Any, depth: Int) {
            guard result.count < limit, depth < 60, let element = object as? NSAccessibilityProtocol else { return }
            let roleGetter: (() -> NSAccessibility.Role?)? = element.accessibilityRole
            let labelGetter: (() -> String?)? = element.accessibilityLabel
            let titleGetter: (() -> String?)? = element.accessibilityTitle
            let valueGetter: (() -> Any?)? = element.accessibilityValue
            let identifierGetter: (() -> String?)? = element.accessibilityIdentifier
            let role = roleGetter?() ?? .unknown
            let label = labelGetter?() ?? titleGetter?() ?? ""
            let value = valueGetter?().map { "\($0)" } ?? ""
            let identifier = identifierGetter?() ?? ""
            let frame = element.accessibilityFrame()
            let visible = frame.width > 0 && frame.height > 0
            if visible, includeAll || !label.isEmpty || !identifier.isEmpty || (interactiveRoles.contains(role) && role != NSAccessibility.Role.staticText && role != NSAccessibility.Role.image) {
                result.append(UINode(element: element, role: role.rawValue.replacingOccurrences(of: "AX", with: ""),
                                     label: label, value: value.count > 80 ? String(value.prefix(80)) + "…" : value,
                                     identifier: identifier, frame: frame, depth: depth))
            }
            let childrenGetter: (() -> [Any]?)? = element.accessibilityChildren
            let contentsGetter: (() -> [Any]?)? = element.accessibilityContents
            let rowsGetter: (() -> [Any]?)? = element.accessibilityRows
            var children = (childrenGetter?() ?? []) + (contentsGetter?() ?? []) + (rowsGetter?() ?? [])
            if let view = object as? NSView {
                children += view.subviews.filter { !$0.isHidden }
            }
            for child in children {
                let id = ObjectIdentifier(child as AnyObject)
                guard visited.insert(id).inserted else { continue }
                walk(child, depth: depth + 1)
            }
        }
        var visited: Set<ObjectIdentifier> = []
        walk(window, depth: 0)
        return result
    }

    var description: String {
        var parts = [role]
        if !label.isEmpty { parts.append("\"\(label)\"") }
        if !value.isEmpty, value != label { parts.append("value=\"\(value)\"") }
        if !identifier.isEmpty { parts.append("id=\(identifier)") }
        parts.append("[\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))]")
        return parts.joined(separator: " ")
    }

    @discardableResult
    func press(in window: NSWindow? = nil) -> Bool {
        if element.accessibilityPerformPress() == true { return true }
        if let window, MouseInput.click(screenPoint: CGPoint(x: frame.midX, y: frame.midY), in: window) { return true }
        if role == "Row" || role == "Cell" || role == "OutlineRow" {
            element.setAccessibilitySelected(true)
            return true
        }
        if element.accessibilityPerformPick() == true { return true }
        return false
    }

    func focus() {
        element.setAccessibilityFocused(true)
        _ = element.accessibilityPerformPress()
    }
}

/// 向本应用窗口投递鼠标单击（无障碍点按不可用时的兜底，如工具栏按钮）
enum MouseInput {
    static func click(screenPoint: CGPoint, in window: NSWindow) -> Bool {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }
}

/// 向本应用窗口投递键盘事件（走正常事件循环，菜单快捷键与 onKeyPress 都能收到）
enum KeyInput {
    private static let special: [String: (UInt16, String)] = [
        "space": (49, " "), "return": (36, "\r"), "enter": (36, "\r"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"),
        "tab": (48, "\t"), "delete": (51, "\u{7f}"),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)), "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
    ]

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49,
    ]

    @discardableResult
    static func send(_ key: String, modifiers: [String], to window: NSWindow) -> Bool {
        let keyCode: UInt16
        let characters: String
        var flags = NSEvent.ModifierFlags()
        if let entry = special[key.lowercased()] {
            (keyCode, characters) = entry
            if (123 ... 126).contains(keyCode) { flags.formUnion([.function, .numericPad]) }
        } else if key.count == 1, let character = key.lowercased().first {
            keyCode = letters[character] ?? 0
            characters = key
        } else {
            return false
        }
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }
}
#endif
