import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// The default presentation surface for every publication supported by BookKit.
///
/// The view selects WebKit, PDFKit, fixed-page, or audiobook presentation from
/// the reader session and keeps native view callbacks synchronized automatically.
public struct BookReaderView: View {
    @ObservedObject private var reader: BookReader

    /// Creates the default presentation for an opened reader session.
    ///
    /// The view observes the reader and automatically chooses the appropriate
    /// presentation engine for its publication.
    public init(reader: BookReader) {
        self.reader = reader
    }

    /// The format-appropriate reader presentation.
    @ViewBuilder
    public var body: some View {
        switch reader.presentationEngine {
        case .reflow, .xhtmlFixed:
            reflowView

        case .bitmapFixed:
            fixedPageView

        case .pdf:
            pdfView

        case .audio:
            BookReaderAudioView(reader: reader)
        }
    }

    @ViewBuilder
    private var reflowView: some View {
        #if canImport(WebKit)
        if let bridge = reader.reflowBridge {
            GeometryReader { geometry in
                pageSwipe(
                    ReflowBookView(bridge: bridge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: geometry.size) {
                            reader.updateViewport(size: geometry.size)
                        }
                )
            }
        } else {
            unavailableView("The WebKit reader could not be created.")
        }
        #else
        unavailableView("WebKit is unavailable on this platform.")
        #endif
    }

    private var fixedPageView: some View {
        pageSwipe(
            FixedPageBookView(
                book: reader.book,
                pageIndex: reader.position.spineIndex,
                showsSpread: reader.showsSpread,
                onLinkActivated: { activation in
                    Task { @MainActor in
                        await reader.activateFixedPageLink(activation)
                    }
                },
                onVisibilityChanged: { visibility in
                    Task { @MainActor in
                        await reader.updateFixedPageVisibility(visibility)
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    @ViewBuilder
    private var pdfView: some View {
        if let data = reader.book.assets.first(where: { $0.id == "pdf-document" })?.data {
            #if canImport(PDFKit) && !os(tvOS)
            PDFBookView(
                data: data,
                pageIndex: reader.position.spineIndex,
                onPageChanged: { index in
                    Task { @MainActor in
                        await reader.updatePDFPage(index)
                    }
                },
                onLinkActivated: { url in
                    Task { @MainActor in
                        await reader.activatePDFLink(url)
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            pdfTextFallback
            #endif
        } else {
            pdfTextFallback
        }
    }

    private var pdfTextFallback: some View {
        let index = min(
            max(reader.position.spineIndex, 0),
            max(reader.book.readingOrder.count - 1, 0)
        )
        return ScrollView {
            pdfFallbackText(
                reader.book.readingOrder.indices.contains(index)
                    ? reader.book.readingOrder[index].content
                    : "No PDF content is available."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder
    private func pdfFallbackText(_ value: String) -> some View {
        #if os(tvOS)
        Text(value)
        #else
        Text(value).textSelection(.enabled)
        #endif
    }

    @ViewBuilder
    private func pageSwipe<Content: View>(_ content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.simultaneousGesture(pageSwipeGesture)
        #endif
    }

    #if !os(tvOS)
    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < 0 {
                    reader.perform { try await $0.next() }
                } else {
                    reader.perform { try await $0.previous() }
                }
            }
    }
    #endif

    private func unavailableView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.largeTitle)
            Text("Reader unavailable")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
