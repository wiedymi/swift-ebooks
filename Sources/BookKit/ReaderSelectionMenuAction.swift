import Foundation

/// An app action in the native text selection menu. The handler receives the
/// selection captured when that menu was built, even if dismissing it clears selection.
@MainActor
public struct ReaderSelectionMenuAction {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let handler: @MainActor (ReaderSelection) -> Void

    public init(id: String, title: String, systemImage: String? = nil,
                handler: @escaping @MainActor (ReaderSelection) -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.handler = handler
    }
}

@MainActor
struct ReaderSelectionMenu {
    let selection: ReaderSelection
    let actions: [ReaderSelectionMenuAction]
}
