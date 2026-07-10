import Foundation
@testable import BookKit

@MainActor
final class MockReflowBridge: ReflowBridge {
    enum Command: Equatable {
        case setContent(html: String, css: String, viewport: Viewport)
        case goToAnchor(String)
        case goToProgression(Double)
        case setReadingMode(ReadingMode)
        case setTheme(Theme)
        case setTypography(Typography)
        case setDecorations([Decoration])
        case setAccessibility(ReaderAccessibilitySettings)
        case setPublicationLayout(PublicationLayout)
        case setNetworkAccessAllowed(Bool)
        case measurePages
    }

    private(set) var commands: [Command] = []

    private let stream: AsyncStream<ReflowBridgeEvent>
    private let continuation: AsyncStream<ReflowBridgeEvent>.Continuation

    var events: AsyncStream<ReflowBridgeEvent> { stream }

    init() {
        var c: AsyncStream<ReflowBridgeEvent>.Continuation!
        stream = AsyncStream<ReflowBridgeEvent> { continuation in
            c = continuation
        }
        continuation = c
    }

    func emit(_ event: ReflowBridgeEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func setContent(html: String, css: String, viewport: Viewport) async throws {
        commands.append(.setContent(html: html, css: css, viewport: viewport))
    }

    func goToAnchor(_ id: String) async throws {
        commands.append(.goToAnchor(id))
    }

    func goToProgression(_ value: Double) async throws {
        commands.append(.goToProgression(value))
    }

    func setReadingMode(_ mode: ReadingMode) async throws {
        commands.append(.setReadingMode(mode))
    }

    func setTheme(_ theme: Theme) async throws {
        commands.append(.setTheme(theme))
    }

    func setTypography(_ typography: Typography) async throws {
        commands.append(.setTypography(typography))
    }

    func setDecorations(_ decorations: [Decoration]) async throws {
        commands.append(.setDecorations(decorations))
    }

    func setAccessibility(_ settings: ReaderAccessibilitySettings) async throws {
        commands.append(.setAccessibility(settings))
    }

    func setPublicationLayout(_ layout: PublicationLayout) async throws {
        commands.append(.setPublicationLayout(layout))
    }

    func setNetworkAccessAllowed(_ allowed: Bool) async throws {
        commands.append(.setNetworkAccessAllowed(allowed))
    }

    func measurePages() async throws {
        commands.append(.measurePages)
    }
}
