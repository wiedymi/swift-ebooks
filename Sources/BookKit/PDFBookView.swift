import Foundation

#if canImport(PDFKit) && canImport(SwiftUI) && !os(tvOS)
@preconcurrency import PDFKit
import SwiftUI

/// A policy-safe PDFKit presentation surface.
///
/// PDFKit handles internal page actions. URL annotations are intercepted and
/// reported through `onLinkActivated`; BookKit never opens them implicitly.
public struct PDFBookView: View {
    private let data: Data
    private let pageIndex: Int
    private let onPageChanged: ((Int) -> Void)?
    private let onLinkActivated: ((URL) -> Void)?

    public init(
        data: Data,
        pageIndex: Int,
        onPageChanged: ((Int) -> Void)? = nil,
        onLinkActivated: ((URL) -> Void)? = nil
    ) {
        self.data = data
        self.pageIndex = max(pageIndex, 0)
        self.onPageChanged = onPageChanged
        self.onLinkActivated = onLinkActivated
    }

    public var body: some View {
        _PDFViewContainer(
            data: data,
            pageIndex: pageIndex,
            onPageChanged: onPageChanged,
            onLinkActivated: onLinkActivated
        )
    }
}

@MainActor
private final class _PDFViewCoordinator: NSObject, @preconcurrency PDFViewDelegate {
    var data: Data? {
        didSet {
            if oldValue != data {
                lastReportedPageIndex = nil
            }
        }
    }
    var onPageChanged: ((Int) -> Void)?
    var onLinkActivated: ((URL) -> Void)?
    private weak var observedView: PDFView?
    private var pageObserver: NSObjectProtocol?
    private var lastReportedPageIndex: Int?

    isolated deinit {
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
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
        guard observedView !== view else { return }
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
        observedView = view
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                self.reportPage(of: view)
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
private struct _PDFViewContainer: UIViewRepresentable {
    let data: Data
    let pageIndex: Int
    let onPageChanged: ((Int) -> Void)?
    let onLinkActivated: ((URL) -> Void)?

    func makeCoordinator() -> _PDFViewCoordinator { _PDFViewCoordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    private func update(_ view: PDFView, coordinator: _PDFViewCoordinator) {
        coordinator.configure(
            view: view,
            onPageChanged: onPageChanged,
            onLinkActivated: onLinkActivated
        )
        if coordinator.data != data {
            coordinator.data = data
            view.document = PDFDocument(data: data)
        }
        if let document = view.document,
           let page = document.page(at: min(pageIndex, max(document.pageCount - 1, 0))),
           view.currentPage !== page
        {
            view.go(to: page)
        }
        coordinator.reportPage(of: view)
    }
}
#elseif os(macOS)
private struct _PDFViewContainer: NSViewRepresentable {
    let data: Data
    let pageIndex: Int
    let onPageChanged: ((Int) -> Void)?
    let onLinkActivated: ((URL) -> Void)?

    func makeCoordinator() -> _PDFViewCoordinator { _PDFViewCoordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    private func update(_ view: PDFView, coordinator: _PDFViewCoordinator) {
        coordinator.configure(
            view: view,
            onPageChanged: onPageChanged,
            onLinkActivated: onLinkActivated
        )
        if coordinator.data != data {
            coordinator.data = data
            view.document = PDFDocument(data: data)
        }
        if let document = view.document,
           let page = document.page(at: min(pageIndex, max(document.pageCount - 1, 0))),
           view.currentPage !== page
        {
            view.go(to: page)
        }
        coordinator.reportPage(of: view)
    }
}
#endif

#endif
