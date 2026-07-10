import Foundation

#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The pages currently presented by ``FixedPageBookView``.
public struct FixedPageVisibility: Sendable, Equatable, Hashable {
    public var primaryPageIndex: Int
    public var pageIndices: [Int]
    public var locator: Locator

    public init(primaryPageIndex: Int, pageIndices: [Int], locator: Locator) {
        self.primaryPageIndex = primaryPageIndex
        self.pageIndices = pageIndices
        self.locator = locator
    }
}

/// A link selected from a fixed-layout page.
public struct FixedPageLinkActivation: Sendable, Equatable, Hashable {
    public var pageIndex: Int
    public var link: PageLink
    public var locator: Locator

    public init(pageIndex: Int, link: PageLink, locator: Locator) {
        self.pageIndex = pageIndex
        self.link = link
        self.locator = locator
    }
}

/// Geometry and publication data supplied to a host-defined fixed-page overlay.
///
/// `imageFrame` is the aspect-fitted page rectangle in the view's coordinate
/// space. Page-link bounds use source pixels with a top-left origin.
public struct FixedPageOverlayContext {
    public var pageIndex: Int
    public var chapter: Chapter
    public var presentation: PagePresentation
    public var locator: Locator
    public var sourceSize: CGSize
    public var imageFrame: CGRect

    public init(
        pageIndex: Int,
        chapter: Chapter,
        presentation: PagePresentation,
        locator: Locator,
        sourceSize: CGSize,
        imageFrame: CGRect
    ) {
        self.pageIndex = pageIndex
        self.chapter = chapter
        self.presentation = presentation
        self.locator = locator
        self.sourceSize = sourceSize
        self.imageFrame = imageFrame
    }

    /// Converts source-pixel bounds into the view coordinate space.
    public func frame(for bounds: PageRectangle) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              imageFrame.width > 0,
              imageFrame.height > 0
        else {
            return .zero
        }
        let proposed = CGRect(
            x: imageFrame.minX + CGFloat(bounds.x) * imageFrame.width / sourceSize.width,
            y: imageFrame.minY + CGFloat(bounds.y) * imageFrame.height / sourceSize.height,
            width: CGFloat(bounds.width) * imageFrame.width / sourceSize.width,
            height: CGFloat(bounds.height) * imageFrame.height / sourceSize.height
        )
        guard proposed.maxX >= imageFrame.minX,
              proposed.minX <= imageFrame.maxX,
              proposed.maxY >= imageFrame.minY,
              proposed.minY <= imageFrame.maxY
        else {
            return .zero
        }
        let minX = max(proposed.minX, imageFrame.minX)
        let minY = max(proposed.minY, imageFrame.minY)
        let maxX = min(proposed.maxX, imageFrame.maxX)
        let maxY = min(proposed.maxY, imageFrame.maxY)
        return CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
    }

    /// Returns an accessible hit target while keeping it clipped to the page.
    public func hitFrame(
        for bounds: PageRectangle,
        minimumSize: CGFloat = 28
    ) -> CGRect {
        guard bounds.x + bounds.width >= 0,
              bounds.x <= Double(sourceSize.width),
              bounds.y + bounds.height >= 0,
              bounds.y <= Double(sourceSize.height)
        else {
            return .zero
        }
        let exact = frame(for: bounds)
        guard exact.maxX >= imageFrame.minX,
              exact.minX <= imageFrame.maxX,
              exact.maxY >= imageFrame.minY,
              exact.minY <= imageFrame.maxY
        else {
            return .zero
        }
        let width = max(exact.width, minimumSize)
        let height = max(exact.height, minimumSize)
        let expanded = CGRect(
            x: exact.midX - width / 2,
            y: exact.midY - height / 2,
            width: width,
            height: height
        )
        let clipped = expanded.intersection(imageFrame)
        return clipped.isNull || clipped.isInfinite ? .zero : clipped
    }
}

/// Presents CBZ, fixed-layout EPUB, image-only EPUB, and DjVu pages.
///
/// The host owns page navigation. `onVisibilityChanged` provides a live locator,
/// `onLinkActivated` routes page links, and the overlay builder can add narration
/// focus, reading-position UI, annotations, or any other app-owned surface.
public struct FixedPageBookView: View {
    private let book: Book
    private let pageIndex: Int
    private let showsSpread: Bool
    private let onLinkActivated: ((FixedPageLinkActivation) -> Void)?
    private let onVisibilityChanged: ((FixedPageVisibility) -> Void)?
    private let overlay: (FixedPageOverlayContext) -> AnyView

    public init(
        book: Book,
        pageIndex: Int,
        showsSpread: Bool = false,
        onLinkActivated: ((FixedPageLinkActivation) -> Void)? = nil,
        onVisibilityChanged: ((FixedPageVisibility) -> Void)? = nil
    ) {
        self.book = book
        self.pageIndex = max(pageIndex, 0)
        self.showsSpread = showsSpread
        self.onLinkActivated = onLinkActivated
        self.onVisibilityChanged = onVisibilityChanged
        overlay = { _ in AnyView(EmptyView()) }
    }

    public init<Overlay: View>(
        book: Book,
        pageIndex: Int,
        showsSpread: Bool = false,
        onLinkActivated: ((FixedPageLinkActivation) -> Void)? = nil,
        onVisibilityChanged: ((FixedPageVisibility) -> Void)? = nil,
        @ViewBuilder overlay: @escaping (FixedPageOverlayContext) -> Overlay
    ) {
        self.book = book
        self.pageIndex = max(pageIndex, 0)
        self.showsSpread = showsSpread
        self.onLinkActivated = onLinkActivated
        self.onVisibilityChanged = onVisibilityChanged
        self.overlay = { AnyView(overlay($0)) }
    }

    public var body: some View {
        let adapter = FixedPageAdapter(book: book)
        let indices = visiblePageIndices(adapter: adapter)
        let primary = indices.contains(pageIndex) ? pageIndex : (indices.first ?? 0)
        let visibility = FixedPageVisibility(
            primaryPageIndex: primary,
            pageIndices: indices,
            locator: book.locator(for: adapter.position(forPageIndex: primary))
        )

        HStack(spacing: 0) {
            ForEach(indices, id: \.self) { index in
                pageView(at: index, adapter: adapter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: visibility) {
            onVisibilityChanged?(visibility)
        }
    }

    @ViewBuilder
    private func pageView(at index: Int, adapter: FixedPageAdapter) -> some View {
        if let data = adapter.asset(forPageIndex: index)?.data,
           let decoded = platformImage(data: data),
           book.readingOrder.indices.contains(index),
           let presentation = book.readingOrder[index].page
        {
            GeometryReader { geometry in
                let chapter = book.readingOrder[index]
                let sourceSize = pageSize(presentation: presentation, fallback: decoded.pixelSize)
                let imageFrame = aspectFit(sourceSize, in: geometry.size)
                let context = FixedPageOverlayContext(
                    pageIndex: index,
                    chapter: chapter,
                    presentation: presentation,
                    locator: book.locator(for: adapter.position(forPageIndex: index)),
                    sourceSize: sourceSize,
                    imageFrame: imageFrame
                )

                ZStack(alignment: .topLeading) {
                    decoded.image
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                        .accessibilityLabel(chapter.title ?? "Page \(index + 1)")
                        .accessibilityValue("Page \(index + 1) of \(book.readingOrder.count)")

                    if let onLinkActivated {
                        ForEach(presentation.links) { link in
                            let frame = context.hitFrame(for: link.bounds)
                            if frame.width > 0, frame.height > 0 {
                                Button {
                                    onLinkActivated(
                                        FixedPageLinkActivation(
                                            pageIndex: index,
                                            link: link,
                                            locator: context.locator
                                        )
                                    )
                                } label: {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                                .accessibilityLabel(link.title ?? "Page link")
                                .accessibilityHint(link.href)
                            }
                        }
                    }

                    overlay(context)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            unavailablePage(index: index)
        }
    }

    private func unavailablePage(index: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
            Text("Page unavailable")
                .font(.headline)
            Text("The image for page \(index + 1) could not be loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func visiblePageIndices(adapter: FixedPageAdapter) -> [Int] {
        let clamped = adapter.pageIndex(for: adapter.position(forPageIndex: pageIndex))
        guard showsSpread else { return [clamped] }
        return adapter.spreads().first(where: { $0.pageIndices.contains(clamped) })?.pageIndices
            ?? [clamped]
    }

    private func pageSize(presentation: PagePresentation, fallback: CGSize) -> CGSize {
        guard let width = presentation.pixelWidth,
              let height = presentation.pixelHeight,
              width > 0,
              height > 0
        else {
            return fallback
        }
        return CGSize(width: width, height: height)
    }

    private func aspectFit(_ source: CGSize, in container: CGSize) -> CGRect {
        guard source.width > 0,
              source.height > 0,
              container.width > 0,
              container.height > 0
        else {
            return .zero
        }
        let scale = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private struct DecodedPageImage {
        var image: Image
        var pixelSize: CGSize
    }

    private func platformImage(data: Data) -> DecodedPageImage? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let size = image.cgImage.map {
            CGSize(width: $0.width, height: $0.height)
        } ?? CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        return DecodedPageImage(image: Image(uiImage: image), pixelSize: size)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        let representation = image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        let size = representation.map {
            CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
        } ?? image.size
        return DecodedPageImage(image: Image(nsImage: image), pixelSize: size)
        #else
        return nil
        #endif
    }
}
#endif
