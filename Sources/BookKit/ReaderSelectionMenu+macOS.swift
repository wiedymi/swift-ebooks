#if os(macOS)
import AppKit
import WebKit
#if canImport(PDFKit)
import PDFKit
#endif

extension ReaderSelectionMenu {
    static func update(_ menu: NSMenu, selectionMenu: Self?) {
        let separatorID = NSUserInterfaceItemIdentifier("org.bookkit.selection.separator")
        for item in menu.items where item is ReaderSelectionMenuItem || item.identifier == separatorID {
            menu.removeItem(item)
        }
        guard let selectionMenu, !selectionMenu.actions.isEmpty else { return }
        if !menu.items.isEmpty {
            let separator = NSMenuItem.separator()
            separator.identifier = separatorID
            menu.addItem(separator)
        }
        for action in selectionMenu.actions {
            let item = ReaderSelectionMenuItem(title: action.title) { action.handler(selectionMenu.selection) }
            item.identifier = NSUserInterfaceItemIdentifier(action.id)
            item.image = action.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(item)
        }
    }
}

@MainActor
private final class ReaderSelectionMenuItem: NSMenuItem {
    private let perform: @MainActor () -> Void

    init(title: String, perform: @escaping @MainActor () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(activate), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        perform = {}
        super.init(coder: coder)
    }
    @objc private func activate() { perform() }
}

final class ReaderSelectionWebView: WKWebView {
    var selectionMenu: (@MainActor () -> ReaderSelectionMenu?)?
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        ReaderSelectionMenu.update(menu, selectionMenu: selectionMenu?())
    }
}

#if canImport(PDFKit)
final class ReaderSelectionPDFView: PDFView {
    var selectionMenu: (@MainActor () -> ReaderSelectionMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        ReaderSelectionMenu.update(menu, selectionMenu: selectionMenu?())
        return menu
    }
}
#endif
#endif
