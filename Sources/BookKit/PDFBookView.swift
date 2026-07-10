import Foundation

#if canImport(PDFKit) && canImport(SwiftUI) && !os(tvOS)
import PDFKit
import SwiftUI

public struct PDFBookView: View {
    private let data: Data
    private let pageIndex: Int

    public init(data: Data, pageIndex: Int) {
        self.data = data
        self.pageIndex = max(pageIndex, 0)
    }

    public var body: some View {
        _PDFViewContainer(data: data, pageIndex: pageIndex)
    }
}

#if os(iOS) || os(visionOS)
private struct _PDFViewContainer: UIViewRepresentable {
    let data: Data
    let pageIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

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

    private func update(_ view: PDFView, coordinator: Coordinator) {
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
    }

    final class Coordinator {
        var data: Data?
    }
}
#elseif os(macOS)
private struct _PDFViewContainer: NSViewRepresentable {
    let data: Data
    let pageIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

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

    private func update(_ view: PDFView, coordinator: Coordinator) {
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
    }

    final class Coordinator {
        var data: Data?
    }
}
#endif

#endif
