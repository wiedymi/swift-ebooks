#if canImport(WebKit)
    import XCTest
    import WebKit
    @testable import BookKit

    @MainActor
    final class ReadingTextPerformanceTests: XCTestCase {
        func testHighlightWorkload() async throws {
            guard ProcessInfo.processInfo.environment["BOOKKIT_MEASURE_TEXT"] == "1" else {
                throw XCTSkip("Set BOOKKIT_MEASURE_TEXT=1 to measure the text renderer")
            }
            let bridge = WebViewReflowBridge()
            bridge.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let html = (0..<2_000).map {
                "<p>Paragraph \($0). This is <em>readable text</em> with enough words to test a long chapter.</p>"
            }.joined()
            try await bridge.setContent(
                html: html, css: "p { margin: 12px; font: 18px Georgia; }",
                viewport: .init(width: 800, height: 600))
            let result = try await bridge.webView.callAsyncJavaScript(
                #"""
                const map = window.BookKitNativeTextMap();
                const marks = [];
                for (let i = 0; i < 200; i++) {
                  const start = map.text.indexOf('readable text', Math.floor(i * map.text.length / 200));
                  if (start < 0) continue;
                  marks.push({ id: String(i), group: 'highlight',
                    locator: { textRange: { start, end: start + 13, quote: 'readable text' } },
                    style: { backgroundColor: '#fff5a8' } });
                }
                const samples = [];
                for (let i = 0; i < 35; i++) {
                  const start = performance.now();
                  window.BookKitNativeApplyTextDecorations(marks);
                  document.body.getBoundingClientRect();
                  if (i >= 5) samples.push(performance.now() - start);
                }
                samples.sort((a, b) => a - b);
                return JSON.stringify({ textLength: map.text.length, marks: marks.length, samples: samples.length,
                  medianMS: samples[Math.floor(samples.length * 0.5)],
                  p95MS: samples[Math.ceil(samples.length * 0.95) - 1],
                  p99MS: samples[Math.ceil(samples.length * 0.99) - 1],
                  userAgent: navigator.userAgent, viewport: [innerWidth, innerHeight] });
                """#, arguments: [:], in: nil, contentWorld: .defaultClient)
            #if os(macOS)
                if let path = ProcessInfo.processInfo.environment["BOOKKIT_TEXT_SNAPSHOT"] {
                    let png: Data = try await withCheckedThrowingContinuation { continuation in
                        bridge.webView.takeSnapshot(with: nil) { image, error in
                            if let error { continuation.resume(throwing: error); return }
                            guard let tiff = image?.tiffRepresentation,
                                  let bitmap = NSBitmapImageRep(data: tiff),
                                  let png = bitmap.representation(using: .png, properties: [:]) else {
                                continuation.resume(throwing: BookError.renderingFailed("Snapshot is unavailable"))
                                return
                            }
                            continuation.resume(returning: png)
                        }
                    }
                    try png.write(to: URL(fileURLWithPath: path))
                }
            #endif
            let report = try XCTUnwrap(result as? String)
            print("BOOKKIT_TEXT_MEASUREMENT \(report)")
            if let path = ProcessInfo.processInfo.environment["BOOKKIT_TEXT_REPORT"] {
                try Data(report.utf8).write(to: URL(fileURLWithPath: path))
            }
        }
    }
#endif
