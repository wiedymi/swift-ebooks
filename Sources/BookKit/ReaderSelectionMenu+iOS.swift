#if os(iOS) || os(visionOS)
import UIKit
import WebKit
#if canImport(PDFKit)
import PDFKit
#endif

extension ReaderSelectionMenu {
    static func update(_ builder: any UIMenuBuilder, selectionMenu: Self?) {
        guard builder.system == .context else { return }
        let identifier = UIMenu.Identifier("org.bookkit.selection")
        if builder.menu(for: identifier) != nil { builder.remove(menu: identifier) }
        guard let selectionMenu, !selectionMenu.actions.isEmpty else { return }
        let menu = UIMenu(title: "", identifier: identifier, options: .displayInline,
            children: selectionMenu.actions.map { action in
                UIAction(title: action.title, image: action.systemImage.flatMap(UIImage.init(systemName:)),
                    identifier: UIAction.Identifier(action.id)) { _ in action.handler(selectionMenu.selection) }
            })
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(menu, afterMenu: .standardEdit)
        } else {
            builder.insertChild(menu, atStartOfMenu: .root)
        }
    }
}

final class ReaderSelectionWebView: WKWebView {
    var selectionMenu: (@MainActor () -> ReaderSelectionMenu?)?
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        ReaderSelectionMenu.update(builder, selectionMenu: selectionMenu?())
    }
}

#if canImport(PDFKit)
final class ReaderSelectionPDFView: PDFView {
    var selectionMenu: (@MainActor () -> ReaderSelectionMenu?)?
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        ReaderSelectionMenu.update(builder, selectionMenu: selectionMenu?())
    }
}
#endif
#endif
