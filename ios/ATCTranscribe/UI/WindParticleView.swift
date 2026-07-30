import MetalKit

/// The transparent Metal layer the wind particles are drawn into, floated over the MLNMapView inside the
/// map's container view (the same sibling-view trick `StarfieldView` uses to sit behind it).
///
/// It is a sibling rather than a MapLibre style layer for one reason: a particle field is per-frame CPU work
/// over a wind grid, which no style layer can express. Being a sibling also means it never touches the
/// style, so nothing here can perturb the style-setup gate or the chart layers.
///
/// Frame rate is pinned to 30 to match the map's own `.lowPower` cap — animating faster than the chart
/// beneath it would spend battery on a mismatch the eye reads as jitter.
final class WindParticleView: MTKView {

    /// Matches `MLNMapView.preferredFramesPerSecond = .lowPower`.
    static let targetFPS = 30

    private let particleRenderer: WindParticleRenderer

    /// nil when Metal is unavailable — the caller then omits the layer entirely rather than showing an
    /// empty view over the chart. A factory rather than a failable initialiser because `UIView.init(frame:)`
    /// is not failable and cannot be overridden as one.
    static func make(frame: CGRect) -> WindParticleView? {
        let device = MTLCreateSystemDefaultDevice()
        guard let renderer = WindParticleRenderer(device: device) else { return nil }
        return WindParticleView(frame: frame, device: device, renderer: renderer)
    }

    private init(frame: CGRect, device: MTLDevice?, renderer: WindParticleRenderer) {
        particleRenderer = renderer
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        // Continuous animation (not setNeedsDisplay-driven): the field is always in motion while visible.
        enableSetNeedsDisplay = false
        isPaused = true
        preferredFramesPerSecond = Self.targetFPS
        autoResizeDrawable = true
        isUserInteractionEnabled = false        // every touch belongs to the map underneath
        delegate = renderer
    }

    required init(coder: NSCoder) { fatalError("WindParticleView is created in code only") }

    /// Feed the renderer. Cheap enough to call on every apply pass — the values are plain assignments and
    /// the particles pick up new data on their next step.
    func apply(fieldSet: WindFieldSet?, level: WindLevel, ramp: WindRamp) {
        assert(Thread.isMainThread, "WindParticleView.apply must run on the main thread")
        assert(preferredFramesPerSecond > 0, "WindParticleView: invalid frame rate")
        particleRenderer.fieldSet = fieldSet
        particleRenderer.level = level
        particleRenderer.ramp = ramp
    }

    /// Where the renderer reads the live camera each frame.
    func setCameraProvider(_ provider: (() -> WindCamera?)?) {
        assert(Thread.isMainThread, "WindParticleView.setCameraProvider must run on the main thread")
        particleRenderer.cameraProvider = provider
    }

    /// Fully stop the layer when it is gated off: paused AND hidden, so there is no display link, no
    /// command buffer, and nothing composited. This is what keeps the overlay's battery cost at zero
    /// whenever the pilot has it switched off, the app is backgrounded, or the device is running hot.
    func setActive(_ on: Bool) {
        assert(Thread.isMainThread, "WindParticleView.setActive must run on the main thread")
        assert(preferredFramesPerSecond == Self.targetFPS, "WindParticleView: frame rate drifted")
        isPaused = !on
        isHidden = !on
    }
}
