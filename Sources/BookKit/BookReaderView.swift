import Foundation

#if canImport(SwiftUI)
import SwiftUI
#if canImport(PDFKit) && !os(tvOS)
import PDFKit
#endif

public enum ReaderPageTurnGesture: Sendable, Equatable {
    /// Swipes turn pages only in paginated or bitmap content.
    case automatic
    case swipe
    case disabled
}

/// Selects presentation and connects native view callbacks to the reader.
public struct BookReaderView: View {
    @ObservedObject private var reader: BookReader
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let pageTurnGesture: ReaderPageTurnGesture
    private let observesSystemAccessibility: Bool
    private var fixedOverlay: (FixedPageOverlayContext) -> AnyView = { _ in AnyView(EmptyView()) }
    private var selectionContent: ((ReaderSelection) -> AnyView)?
    #if canImport(PDFKit) && !os(tvOS)
    private var configurePDF: (@MainActor (PDFView) -> Void)?
    #endif

    public init(reader: BookReader, pageTurnGesture: ReaderPageTurnGesture = .automatic,
                observesSystemAccessibility: Bool = true) {
        self.reader = reader
        self.pageTurnGesture = pageTurnGesture
        self.observesSystemAccessibility = observesSystemAccessibility
    }

    /// Adds app-defined controls while preserving the system copy menu.
    public func selectionActions<Actions: View>(@ViewBuilder _ actions: @escaping (ReaderSelection) -> Actions) -> Self {
        var view = self
        view.selectionContent = { AnyView(actions($0)) }
        return view
    }

    public func fixedPageOverlay<Overlay: View>(@ViewBuilder _ overlay: @escaping (FixedPageOverlayContext) -> Overlay) -> Self {
        var view = self
        view.fixedOverlay = { AnyView(overlay($0)) }
        return view
    }

    #if canImport(PDFKit) && !os(tvOS)
    /// Runs once for each native PDF view. Preserve its session delegate.
    public func configurePDFView(_ configure: @escaping @MainActor (PDFView) -> Void) -> Self {
        var view = self
        view.configurePDF = configure
        return view
    }
    #endif

    public var body: some View {
        content
            .overlay(alignment: .bottom) {
                if let selection = reader.selection, let selectionContent {
                    selectionContent(selection)
                }
            }
            .task(id: systemAccessibility) {
                if observesSystemAccessibility {
                    do { try await reader.setAccessibility(systemAccessibility) }
                    catch { reader.report(error) }
                }
            }
            .task(id: scenePhase) {
                guard scenePhase != .active else { return }
                do { try await reader.saveState() }
                catch { reader.report(error) }
            }
    }

    private var systemAccessibility: ReaderAccessibilitySettings {
        var settings = reader.accessibility
        if observesSystemAccessibility {
            settings.isVoiceOverEnabled = voiceOverEnabled
            settings.prefersReducedMotion = reduceMotion
        }
        return settings
    }

    @ViewBuilder
    private var content: some View {
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
                },
                overlay: fixedOverlay
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
                },
                configureView: { view in
                    reader.pdfView = view
                    configurePDF?(view)
                },
                locator: reader.locator,
                decorations: reader.decorations,
                onSelectionChanged: reader.updatePDFSelection,
                onDecorationTapped: { reader.eventHub.yield(.decorationTapped($0)) },
                onError: { reader.report($0) }
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
        content.simultaneousGesture(pageSwipeGesture, including: allowsPageSwipe ? .all : .subviews)
        #endif
    }

    private var allowsPageSwipe: Bool {
        guard reader.selection == nil, !reader.accessibility.isVoiceOverEnabled else { return false }
        switch pageTurnGesture {
        case .disabled: return false
        case .swipe: return true
        case .automatic:
            return reader.supportsSpreads || reader.preferences.readingMode == .paginated
        }
    }

    #if !os(tvOS)
    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard allowsPageSwipe, abs(value.translation.width) > abs(value.translation.height) else { return }
                let next = reader.book.presentation.readingProgression == .rightToLeft
                    ? value.translation.width > 0 : value.translation.width < 0
                if next {
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
