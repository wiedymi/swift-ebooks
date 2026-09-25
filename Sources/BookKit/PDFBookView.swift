import Foundation

#if canImport(PDFKit) && canImport(SwiftUI) && !os(tvOS)
@preconcurrency import PDFKit
import SwiftUI

/// A policy-safe PDFKit presentation surface.
///
/// PDFKit handles internal page actions. URL annotations are intercepted and
/// reported through `onLinkActivated`; BookKit never opens them implicitly.
public struct PDFBookView: View {
    private var content: _PDFViewContainer

    public init(
        data: Data,
        pageIndex: Int,
        onPageChanged: ((Int) -> Void)? = nil,
        onLinkActivated: ((URL) -> Void)? = nil,
        configureView: (@MainActor (PDFView) -> Void)? = nil,
        locator: Locator? = nil,
        decorations: [Decoration] = [],
        onSelectionChanged: (([PDFTextSelection]) -> Void)? = nil,
        onDecorationTapped: ((DecorationTapEvent) -> Void)? = nil,
        onError: ((BookError) -> Void)? = nil
    ) {
        content = _PDFViewContainer(
            data: data, pageIndex: max(pageIndex, 0),
            onPageChanged: onPageChanged, onLinkActivated: onLinkActivated,
            configureView: configureView, locator: locator, decorations: decorations,
            onSelectionChanged: onSelectionChanged, onDecorationTapped: onDecorationTapped,
            onError: onError
        )
    }

    public var body: some View { content }

    func nativeSelectionMenu(_ menu: @escaping @MainActor () -> ReaderSelectionMenu?) -> Self {
        var view = self
        view.content.selectionMenu = menu
        return view
    }

}

@MainActor
private final class _PDFViewCoordinator: NSObject, @preconcurrency PDFViewDelegate {
    var data: Data? {
        didSet {
            if oldValue != data {
                lastReportedPageIndex = nil
                lastLocator = nil
                lastSelection = []
            }
        }
    }
    var onPageChanged: ((Int) -> Void)?
    var onLinkActivated: ((URL) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var textSupport: PDFTextSupport?
    private var lastLocator: Locator?
    private var lastSelection: [PDFTextSelection] = []
    var onSelectionChanged: (([PDFTextSelection]) -> Void)?
    var onDecorationTapped: ((DecorationTapEvent) -> Void)?
    private var lastReportedPageIndex: Int?

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(
        view: PDFView,
        onPageChanged: ((Int) -> Void)?,
        onLinkActivated: ((URL) -> Void)?
    ) {
        self.onPageChanged = onPageChanged
        self.onLinkActivated = onLinkActivated
        view.delegate = self
        guard textSupport?.view !== view else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        textSupport = PDFTextSupport(view: view)
        let selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let selection = self.textSupport?.selections() ?? []
                guard selection != self.lastSelection else { return }
                self.lastSelection = selection
                self.onSelectionChanged?(selection)
            }
        }
        let annotationObserver = NotificationCenter.default.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { [weak self] notification in
            guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                  let id = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "BookKitDecorationID")) as? String,
                  let rawGroup = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "BookKitDecorationGroup")) as? String,
                  let group = DecorationGroup(rawValue: rawGroup) else { return }
            Task { @MainActor [weak self] in
                if let event = self?.textSupport?.tapped(id: id, group: group) {
                    self?.onDecorationTapped?(event)
                }
            }
        }
        let pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                self.reportPage(of: view)
            }
        }
        observers = [selectionObserver, annotationObserver, pageObserver]
    }

    func updateText(locator: Locator?, decorations: [Decoration], onError: ((BookError) -> Void)?) {
        textSupport?.apply(decorations)
        if let locator, locator != lastLocator {
            lastLocator = locator
            if locator.textRange != nil {
                do { try textSupport?.navigate(to: locator) }
                catch { onError?(BookError.from(error)) }
            }
        }
    }

    func reportPage(of view: PDFView) {
        guard let document = view.document,
              let page = view.currentPage
        else {
            return
        }
        let index = document.index(for: page)
        guard index >= 0, index != lastReportedPageIndex else { return }
        lastReportedPageIndex = index
        onPageChanged?(index)
    }

    func pdfViewWillClick(onLink _: PDFView, with url: URL) {
        onLinkActivated?(url)
    }
}

#if os(iOS) || os(visionOS)
private typealias PDFPlatformViewRepresentable = UIViewRepresentable
#elseif os(macOS)
private typealias PDFPlatformViewRepresentable = NSViewRepresentable
#endif

private struct _PDFViewContainer: PDFPlatformViewRepresentable {
    var selectionMenu: (@MainActor () -> ReaderSelectionMenu?)?
    let data: Data
    let pageIndex: Int
    let onPageChanged: ((Int) -> Void)?
    let onLinkActivated: ((URL) -> Void)?
    let configureView: (@MainActor (PDFView) -> Void)?
    let locator: Locator?
    let decorations: [Decoration]
    let onSelectionChanged: (([PDFTextSelection]) -> Void)?
    let onDecorationTapped: ((DecorationTapEvent) -> Void)?
    let onError: ((BookError) -> Void)?

    func makeCoordinator() -> _PDFViewCoordinator { _PDFViewCoordinator() }

    #if os(iOS) || os(visionOS)
    func makeUIView(context: Context) -> PDFView { makeView(coordinator: context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) { update(view, coordinator: context.coordinator) }
    #elseif os(macOS)
    func makeNSView(context: Context) -> PDFView { makeView(coordinator: context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) { update(view, coordinator: context.coordinator) }
    #endif

    private func makeView(coordinator: _PDFViewCoordinator) -> PDFView {
        let view = ReaderSelectionPDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        configureView?(view)
        update(view, coordinator: coordinator)
        return view
    }

    private func update(_ view: PDFView, coordinator: _PDFViewCoordinator) {
        (view as? ReaderSelectionPDFView)?.selectionMenu = selectionMenu
        coordinator.onSelectionChanged = onSelectionChanged
        coordinator.onDecorationTapped = onDecorationTapped
        coordinator.configure(view: view, onPageChanged: onPageChanged, onLinkActivated: onLinkActivated)
        if coordinator.data != data {
            coordinator.data = data
            view.document = PDFDocument(data: data)
        }
        if let document = view.document,
           let page = document.page(at: min(pageIndex, max(document.pageCount - 1, 0))),
           view.currentPage !== page {
            view.go(to: page)
        }
        coordinator.updateText(locator: locator, decorations: decorations, onError: onError)
        coordinator.reportPage(of: view)
    }
}
#endif
