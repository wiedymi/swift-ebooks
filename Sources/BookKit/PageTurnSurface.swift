#if canImport(MetalKit) && canImport(CoreImage) && !os(visionOS)
import MetalKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore

/// Core Image's paper curl runs on Metal. Images and filters are prepared once
/// per turn; the display loop only changes time and submits the current frame.
@MainActor
final class PageTurnSurface: MTKView, MTKViewDelegate {
    private enum Frame {
        case idle
        case holding(CIImage)
        case turning(PageTurnAnimation)
    }

    private var frameState: Frame = .idle
    private let imageContext: CIContext?
    private let commandQueue: MTLCommandQueue?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    var canRender: Bool { imageContext != nil && commandQueue != nil }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        imageContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        commandQueue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = true
        isHidden = true
        preferredFramesPerSecond = 60
        delegate = self
        #if os(macOS)
        setAccessibilityElement(false)
        #else
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        #endif
    }

    required init(coder: NSCoder) { fatalError("PageTurnSurface is created by the reader") }

    func hold(_ image: CGImage) {
        drawableSize = CGSize(width: image.width, height: image.height)
        frameState = .holding(CIImage(cgImage: image))
        isHidden = false
        isPaused = true
        draw()
    }

    func animate(from: CGImage, to: CGImage, transition: PageTransition, forward: Bool) {
        frameState = .turning(PageTurnAnimation(from: from, to: to, transition: transition, forward: forward))
        isHidden = false
        isPaused = false
    }

    func clear() {
        isPaused = true
        isHidden = true
        frameState = .idle
        releaseDrawables()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let output: CIImage
        switch frameState {
        case .idle: return
        case .holding(let image): output = image
        case .turning(let animation):
            let elapsed = CACurrentMediaTime() - animation.startedAt
            if elapsed >= animation.duration { clear(); return }
            output = animation.image(at: elapsed / animation.duration)
        }
        guard let imageContext, let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { clear(); return }
        let bounds = CGRect(origin: .zero, size: drawableSize)
        imageContext.render(output, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}

@MainActor
private final class PageTurnAnimation {
    let startedAt = CACurrentMediaTime()
    let duration: TimeInterval
    private let from: CIImage
    private let to: CIImage
    private let bounds: CGRect
    private let forward: Bool
    private let curl: (any CIFilter & CIPageCurlWithShadowTransition)?

    init(from: CGImage, to: CGImage, transition: PageTransition, forward: Bool) {
        self.from = CIImage(cgImage: from)
        self.to = CIImage(cgImage: to)
        bounds = CGRect(x: 0, y: 0, width: from.width, height: from.height)
        self.forward = forward
        duration = transition == .curl ? 0.46 : 0.24
        if transition == .curl {
            let filter = CIFilter.pageCurlWithShadowTransition()
            // Going back plays the incoming sheet in reverse, rather than
            // curling the outgoing sheet from the wrong edge.
            let sheet = forward ? self.from : self.to
            filter.inputImage = sheet
            filter.targetImage = forward ? self.to : self.from
            filter.backsideImage = sheet.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.15, kCIInputContrastKey: 1.0, kCIInputBrightnessKey: 0.0
            ])
            filter.extent = bounds
            filter.shadowExtent = bounds
            filter.angle = -.pi / 7
            filter.radius = Float(bounds.width * 0.09)
            filter.shadowSize = Float(bounds.width * 0.04)
            filter.shadowAmount = 0.65
            curl = filter
        } else { curl = nil }
    }

    func image(at value: Double) -> CIImage {
        let time = min(max(value, 0), 1)
        let eased = time * time * (3 - 2 * time)
        if let curl {
            curl.time = Float(forward ? eased : 1 - eased)
            return (curl.outputImage ?? to).cropped(to: bounds)
        }
        let direction: CGFloat = forward ? -1 : 1
        let outgoing = from.transformed(by: CGAffineTransform(translationX: direction * bounds.width * eased, y: 0))
        let incoming = to.transformed(by: CGAffineTransform(translationX: -direction * bounds.width * (1 - eased), y: 0))
        return incoming.composited(over: outgoing).cropped(to: bounds)
    }
}
#endif
