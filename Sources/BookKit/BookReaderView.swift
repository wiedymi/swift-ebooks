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
    private let onCenterTap: (() -> Void)?
    private var fixedOverlay: (FixedPageOverlayContext) -> AnyView = { _ in AnyView(EmptyView()) }
    private var textMagnificationRange: ClosedRange<Double>?
    private var nativeSelectionActions: [ReaderSelectionMenuAction] = []
    private var onImageTapped: ((Asset) -> Void)?
    private var onDecorationTapped: ((DecorationTapEvent) -> Void)?
    private var selectionContent: ((ReaderSelection) -> AnyView)?
    #if canImport(PDFKit) && !os(tvOS)
    private var configurePDF: (@MainActor (PDFView) -> Void)?
    #endif

    public init(reader: BookReader, pageTurnGesture: ReaderPageTurnGesture = .automatic,
                observesSystemAccessibility: Bool = true, onCenterTap: (() -> Void)? = nil) {
        self.reader = reader
        self.pageTurnGesture = pageTurnGesture
        self.observesSystemAccessibility = observesSystemAccessibility
        self.onCenterTap = onCenterTap
    }

    /// Adds app-defined controls while preserving the system copy menu.
    public func selectionActions<Actions: View>(@ViewBuilder _ actions: @escaping (ReaderSelection) -> Actions) -> Self {
        var view = self
        view.selectionContent = { AnyView(actions($0)) }
        return view
    }

    /// Adds actions to the native reflow and PDF text selection menus.
    public func selectionMenuActions(_ actions: [ReaderSelectionMenuAction]) -> Self {
        var view = self
        view.nativeSelectionActions = actions
        return view
    }

    /// Replaces native page zoom with live text resizing in reflowable books.
    public func textMagnification(fontSizeRange: ClosedRange<Double>) -> Self {
        var view = self
        view.textMagnificationRange = fontSizeRange
        return view
    }

    public func onDecorationTap(_ action: @escaping (DecorationTapEvent) -> Void) -> Self {
        var view = self
        view.onDecorationTapped = action
        return view
    }

    /// Opens embedded, unlinked images through host UI. Linked images retain navigation.
    /// Without a handler, image taps keep the normal reader tap behavior.
    public func onImageTap(_ action: @escaping (Asset) -> Void) -> Self {
        var view = self
        view.onImageTapped = action
        return view
    }

    private var selectionMenu: @MainActor () -> ReaderSelectionMenu? {
        { [weak reader, nativeSelectionActions] in
            guard let selection = reader?.selection, !nativeSelectionActions.isEmpty else { return nil }
            return ReaderSelectionMenu(selection: selection, actions: nativeSelectionActions)
        }
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
            .task {
                for await event in reader.events {
                    guard !Task.isCancelled else { return }
                    if case let .decorationTapped(event) = event { onDecorationTapped?(event) }
                    if case let .bridgeMessage(name, .object(payload)) = event,
                       name == "bookkit.tap", case let .number(x)? = payload["x"] {
                        if let onImageTapped,
                           case let .string(encodedID)? = payload["imageID"],
                           let data = Data(base64Encoded: encodedID),
                           let id = String(data: data, encoding: .utf8),
                           let asset = reader.book.assets.last(where: {
                               $0.id == id && $0.mediaType.lowercased().hasPrefix("image/") && $0.data?.isEmpty == false
                           }) {
                            onImageTapped(asset)
                        } else {
                            handleTap(horizontalFraction: x)
                        }
                    }
                }
            }
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
                let content = pageSwipe(
                    ReflowBookView(bridge: bridge, selectionMenu: selectionMenu,
                        allowsPageZoom: textMagnificationRange == nil || reader.book.presentation.layout != .reflowable)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: textMagnificationRange == nil || reader.book.presentation.layout != .reflowable) {
                            do {
                                try await bridge.setPageZoomAllowed(textMagnificationRange == nil || reader.book.presentation.layout != .reflowable)
                            } catch is CancellationError { }
                            catch { reader.report(error) }
                        }
                        .task(id: geometry.size) {
                            reader.updateViewport(size: geometry.size)
                        }
                )
                #if !os(tvOS)
                if let range = textMagnificationRange, reader.book.presentation.layout == .reflowable {
                    content.modifier(ReaderTextMagnification(reader: reader, range: range))
                } else { content }
                #else
                content
                #endif
            }
        } else {
            unavailableView("The WebKit reader could not be created.")
        }
        #else
        unavailableView("WebKit is unavailable on this platform.")
        #endif
    }

    private var fixedPageView: some View {
        pageTap(pageSwipe(
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
        ))
    }

    @ViewBuilder
    private var pdfView: some View {
        if let data = reader.book.assets.first(where: { $0.id == "pdf-document" })?.data {
            #if canImport(PDFKit) && !os(tvOS)
            pageTap(PDFBookView(
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
            .nativeSelectionMenu(selectionMenu)
            .frame(maxWidth: .infinity, maxHeight: .infinity), ignoresPDFDecorations: true)
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

    @ViewBuilder
    private func pageTap<Content: View>(_ content: Content, ignoresPDFDecorations: Bool = false) -> some View {
        #if os(tvOS)
        content
        #else
        GeometryReader { geometry in
            content.simultaneousGesture(SpatialTapGesture().onEnded { value in
                #if canImport(PDFKit)
                if ignoresPDFDecorations, hitsPDFDecoration(at: value.location) { return }
                #endif
                handleTap(horizontalFraction: value.location.x / max(geometry.size.width, 1))
            })
        }
        #endif
    }

    #if canImport(PDFKit) && !os(tvOS)
    private func hitsPDFDecoration(at point: CGPoint) -> Bool {
        guard let view = reader.pdfView else { return false }
        var point = point
        #if os(macOS)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        #endif
        guard let page = view.page(for: point, nearest: false) else { return false }
        let pagePoint = view.convert(point, to: page)
        return page.annotations.contains { annotation in
            annotation.bounds.contains(pagePoint)
                && annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "BookKitDecorationGroup")) as? String == DecorationGroup.highlight.rawValue
        }
    }
    #endif

    private func handleTap(horizontalFraction: Double) {
        guard horizontalFraction.isFinite, reader.selection == nil,
              !reader.accessibility.isVoiceOverEnabled else { return }
        guard allowsPageSwipe, horizontalFraction < 0.25 || horizontalFraction > 0.75 else {
            onCenterTap?()
            return
        }
        let next = reader.book.presentation.readingProgression == .rightToLeft
            ? horizontalFraction < 0.25 : horizontalFraction > 0.75
        reader.perform { reader in
            if next { try await reader.next() } else { try await reader.previous() }
        }
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
