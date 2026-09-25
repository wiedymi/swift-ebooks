import Foundation

#if canImport(WebKit)
import WebKit
#if canImport(MetalKit) && !os(visionOS)
import CoreImage

/// Owns transient page images only. ReaderStateActor remains the position owner.
@MainActor
final class ReflowPageTurnRuntime {
    weak var surface: PageTurnSurface?
    private var requestID: UUID?

    func cancel() {
        requestID = nil
        surface?.clear()
    }

    func perform(in webView: WKWebView, transition: PageTransition, forward: Bool,
                 operation: @MainActor () async throws -> Void) async throws {
        cancel()
        guard transition != .none, let surface, surface.canRender,
              webView.window != nil, webView.bounds.width > 1, webView.bounds.height > 1 else {
            try await operation()
            return
        }
        let id = UUID()
        requestID = id
        let size = webView.bounds.size
        let before = await PageSnapshot.capture(webView)
        if Task.isCancelled { if requestID == id { cancel() }; throw CancellationError() }
        guard requestID == id else { return }
        guard webView.bounds.size == size, let before else {
            if requestID == id { cancel() }
            try await operation()
            return
        }
        surface.hold(before)
        do { try await operation() }
        catch { if requestID == id { cancel() }; throw error }
        guard requestID == id, webView.window != nil, webView.bounds.size == size else {
            if requestID == id { cancel() }
            return
        }
        let after = await PageSnapshot.capture(webView)
        if Task.isCancelled { if requestID == id { cancel() }; throw CancellationError() }
        guard requestID == id, webView.bounds.size == size, let after,
              before.width == after.width, before.height == after.height else {
            if requestID == id { cancel() }
            return
        }
        surface.animate(from: before, to: after, transition: transition, forward: forward)
    }
}

/// WebKit snapshot callbacks can be delayed while a window is hidden. Bound the
/// wait and release the continuation on timeout or cancellation; a late image is ignored.
@MainActor
private final class PageSnapshot {
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var timeout: Task<Void, Never>?

    static func capture(_ webView: WKWebView) async -> CGImage? {
        let request = PageSnapshot()
        let size = webView.bounds.size
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1, size.width <= 16_384, size.height <= 16_384 else { return nil }
        #if os(macOS)
        let scale = webView.window?.backingScaleFactor ?? 1
        #else
        let scale = webView.window?.screen.scale ?? 1
        #endif
        // Two RGBA images use at most about 16 MiB, before GPU working storage.
        let maxPixels = 2_000_000.0
        let pixelWidth = min(size.width * scale, sqrt(maxPixels * size.width / size.height))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: floor(pixelWidth / max(scale, 1)))
        configuration.afterScreenUpdates = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.continuation = continuation
                guard !Task.isCancelled else { request.finish(nil); return }
                request.timeout = Task { @MainActor [weak request] in
                    do { try await Task.sleep(for: .milliseconds(750)) }
                    catch { return }
                    request?.finish(nil)
                }
                webView.takeSnapshot(with: configuration) { image, _ in
                    #if os(macOS)
                    let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    #else
                    let cgImage = image?.cgImage
                    #endif
                    guard let cgImage, cgImage.width > 0, cgImage.height > 0,
                          cgImage.width <= 2_100_000 / cgImage.height else {
                        request.finish(nil)
                        return
                    }
                    request.finish(cgImage)
                }
            }
        } onCancel: {
            Task { @MainActor in request.finish(nil) }
        }
    }

    private func finish(_ image: CGImage?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: image)
    }
}
#else
@MainActor
final class ReflowPageTurnRuntime {
    func cancel() {}
    func perform(in webView: WKWebView, transition: PageTransition, forward: Bool,
                 operation: @MainActor () async throws -> Void) async throws {
        try await operation()
    }
}
#endif
#endif
