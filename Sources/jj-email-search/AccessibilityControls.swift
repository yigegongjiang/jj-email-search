import AppKit

final class AccessibleSearchField: NSSearchField {
    var changed: (() -> Void)?
    override func setAccessibilityValue(_ value: Any?) {
        if let value = value as? String {
            stringValue = value
            changed?()
        } else {
            super.setAccessibilityValue(value)
        }
    }
}

final class AccessiblePopUpCell: NSPopUpButtonCell {
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) {
            return true
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}

class AccessiblePopUp: NSPopUpButton {
    override class var cellClass: AnyClass? {
        get { AccessiblePopUpCell.self }
        set { _ = newValue }
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let title = value as? String else { return }
        let index = itemArray.firstIndex { $0.title == title || ($0.representedObject as? String) == title }
        guard let index else { return }
        selectItem(at: index)
        if let action {
            _ = sendAction(action, to: target)
        }
    }
}

final class AccessibleTable: NSTableView {
    override func accessibilityValue() -> Any? {
        selectedRowIndexes.map(String.init).joined(separator: ",")
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) {
            return true
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard isEnabled, let text = value as? String else { return }
        let rows = text.split(separator: ",").compactMap { Int($0) }
        guard rows.allSatisfy({ $0 >= 0 && $0 < numberOfRows }) else { return }
        selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        if let row = rows.last {
            scrollRowToVisible(row)
        }
    }
}

@MainActor
func titlebarControls(_ window: NSWindow, _ buttons: [NSButton]) {
    let stack = NSStackView(views: buttons)
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    for button in buttons { button.bezelStyle = .rounded; button.controlSize = .small }
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .right
    stack.frame = NSRect(
        x: 0,
        y: 0,
        width: buttons.reduce(12) { $0 + max(64, $1.intrinsicContentSize.width) + 6 },
        height: 28
    )
    accessory.view = stack
    window.addTitlebarAccessoryViewController(accessory)
}

@MainActor
func label(_ text: String, identifier: String? = nil) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.lineBreakMode = .byTruncatingTail
    view.setAccessibilityIdentifier(identifier)
    return view
}
