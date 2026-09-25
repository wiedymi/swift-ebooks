#if canImport(SwiftUI) && !os(tvOS)
import SwiftUI

/// Resize text during the pinch while native page zoom remains disabled.
/// One task applies sizes in order and keeps only the latest pending size.
struct ReaderTextMagnification: ViewModifier {
    @ObservedObject var reader: BookReader
    let range: ClosedRange<Double>
    @GestureState private var startingSize: Double?
    @State private var pendingSize: Double?
    @State private var operation: Task<Void, Never>?

    func body(content: Content) -> some View {
        gestures(content)
            .onDisappear { pendingSize = nil; operation?.cancel() }
    }

    @ViewBuilder
    private func gestures(_ content: Content) -> some View {
        if #available(iOS 17, macOS 14, visionOS 1, *) {
            content.highPriorityGesture(MagnifyGesture()
                .updating($startingSize) { _, state, _ in
                    if state == nil { state = reader.preferences.typography.fontSize }
                }
                .onChanged { request(scale: $0.magnification) })
        } else {
            content.highPriorityGesture(MagnificationGesture()
                .updating($startingSize) { _, state, _ in
                    if state == nil { state = reader.preferences.typography.fontSize }
                }
                .onChanged { request(scale: $0) })
        }
    }

    private func request(scale: Double) {
        let size = (startingSize ?? reader.preferences.typography.fontSize) * scale
        guard size.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound > 0 else { return }
        pendingSize = min(max(size, range.lowerBound), range.upperBound)
        guard operation == nil else { return }
        operation = Task {
            defer { operation = nil }
            do {
                while let size = pendingSize {
                    pendingSize = nil
                    try Task.checkCancellation()
                    var typography = reader.preferences.typography
                    guard typography.fontSize != size else { continue }
                    typography.fontSize = size
                    try await reader.setTypography(typography)
                }
            } catch is CancellationError { }
            catch { pendingSize = nil; reader.report(error) }
        }
    }
}
#endif
