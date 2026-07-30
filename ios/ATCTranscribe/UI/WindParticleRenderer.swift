import MetalKit
import QuartzCore
import simd

/// Vertex layout shared with `WindShaders.metal` (`WindSegVertex`). Field order and padding must match.
struct WindSegVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct WindSegUniforms {
    var viewportSize: SIMD2<Float>
    var alpha: Float
}

private struct WindFadeUniforms {
    var uvTransform: simd_float3x3
    var fade: Float
}

/// The animated winds-aloft particle field: a few thousand tracers advected through the GFS wind grid,
/// each leaving a fading slipstream.
///
/// **How the trails work.** Nothing stores a particle's history. Each frame draws only the one short
/// segment the particle just travelled, into a persistent offscreen texture that is copied forward every
/// frame at 96% brightness. The exponential decay of those copies IS the trail — which costs one
/// full-screen pass regardless of trail length, instead of a growing vertex list per particle.
///
/// That same copy-forward pass is where the layer earns its keep during a pan: the previous texture is
/// re-registered through the frame's map motion, so the slipstreams stay attached to the terrain rather
/// than smearing across the screen.
///
/// **Speed is legibility, not physics.** Direction always comes from the projection (see
/// `WindViewportTransform.screenVelocity`), so the flow is honest. The magnitude is a scaled function of
/// speed in knots: drawn to true scale, particles would be invisible at continental zoom and streak off
/// screen on an approach chart.
///
/// NASA/JPL Power-of-10: fixed particle pool, no allocation in the frame loop, every loop bounded by a
/// named cap, no recursion, all GPU objects optional-guarded so a device without them renders nothing
/// rather than trapping.
final class WindParticleRenderer: NSObject, MTKViewDelegate {

    // Caps and tuning (rule 2: every loop below is bounded by one of these).
    /// Particle pool. Sized for a readable field rather than a dense one: the chart underneath is the
    /// primary document, and 3500 tracers at flight levels closed into solid bands.
    static let maxParticles = 2300
    /// Frames a particle lives before respawning. Long enough for a readable streak; short enough that the
    /// field keeps reseeding into areas the pilot pans into.
    static let baseLifeFrames: Float = 150
    /// Per-frame trail decay. At 30 fps this is a ~0.9 s half-life, which is what turns a one-frame step
    /// into a streak long enough to read as a slipstream rather than a dash. Shorter looked like noise.
    static let trailFade: Float = 0.968
    /// Trail textures are rendered at half the drawable's resolution. At full resolution the ping-pong pair
    /// costs ~90 MB on a 13" iPad, and a glow trail loses nothing visible to the halving.
    static let trailScale: CGFloat = 0.5
    /// Visible longitude span (degrees) where the layer is fully opaque, and where it has faded out. Beyond
    /// the upper bound a single affine no longer approximates the globe across the screen.
    static let fullAlphaSpan = 30.0
    static let cutoffSpan = 45.0
    static let segmentWidth: Float = 2.0
    /// Shortest streak drawn, in points. A frame's true displacement in light air is a fraction of a
    /// point — a sliver that covers no sample point and rasterises to NOTHING, so calm regions rendered
    /// as empty space rather than as slow air. Every particle now paints at least a short dash along its
    /// direction of travel; fast air still stretches proportionally.
    static let minSegmentLength: Float = 2.2
    static let inflightFrames = 3

    /// The decoded column. Set from the coordinator; changing it reseeds nothing — particles simply start
    /// sampling the new data.
    var fieldSet: WindFieldSet?
    var level: WindLevel = .surface
    var ramp: WindRamp = .forTheme(.cockpit)
    /// Reads the live map camera on the main thread. Returns nil when the map is gone or degenerate.
    var cameraProvider: (() -> WindCamera?)?

    private struct Particle {
        var x: Float = 0, y: Float = 0
        var prevX: Float = 0, prevY: Float = 0
        var age: Float = 0
        var life: Float = WindParticleRenderer.baseLifeFrames
        var speedKt: Float = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var segmentPipeline: MTLRenderPipelineState?
    private var fadePipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var trailFront: MTLTexture?
    private var trailBack: MTLTexture?
    private var vertexBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inflight = DispatchSemaphore(value: WindParticleRenderer.inflightFrames)

    private var particles: [Particle] = []
    private var vertices: [WindSegVertex] = []
    private var viewSize = CGSize.zero
    private var lastCamera: WindViewportTransform?
    private var lastFrameTime: CFTimeInterval = 0
    private var rng = SystemRandomNumberGenerator()

    /// nil when Metal is unavailable (the caller then skips the whole layer).
    init?(device: MTLDevice?) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        buildPipelines()
        guard segmentPipeline != nil, fadePipeline != nil, compositePipeline != nil else { return nil }
        particles.reserveCapacity(Self.maxParticles)
        vertices.reserveCapacity(Self.maxParticles * 6)
        buildBuffers()
    }


    // MARK: - setup

    private func buildPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }
        segmentPipeline = pipeline(library, vertex: "windSegmentVertex", fragment: "windSegmentFragment")
        fadePipeline = pipeline(library, vertex: "windQuadVertex", fragment: "windFadeFragment", blend: false)
        compositePipeline = pipeline(library, vertex: "windQuadVertex", fragment: "windCompositeFragment")
    }

    /// All three pipelines write premultiplied alpha, so the source factor is one rather than srcAlpha.
    private func pipeline(_ library: MTLLibrary, vertex: String, fragment: String,
                          blend: Bool = true) -> MTLRenderPipelineState? {
        assert(!vertex.isEmpty && !fragment.isEmpty, "WindParticleRenderer: unnamed shader function")
        guard let vfn = library.makeFunction(name: vertex), let ffn = library.makeFunction(name: fragment) else {
            return nil
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vfn
        d.fragmentFunction = ffn
        guard let attachment = d.colorAttachments[0] else { return nil }
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = blend
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    private func buildBuffers() {
        assert(Self.maxParticles > 0, "WindParticleRenderer: empty particle pool")
        assert(Self.inflightFrames > 0, "WindParticleRenderer: no in-flight frames")
        let bytes = Self.maxParticles * 6 * MemoryLayout<WindSegVertex>.stride
        vertexBuffers = (0..<Self.inflightFrames).compactMap {
            _ in device.makeBuffer(length: bytes, options: .storageModeShared)
        }
    }

    private func makeTrailTextures(drawable: CGSize) {
        assert(drawable.width > 0 && drawable.height > 0, "WindParticleRenderer: empty drawable")
        assert(Self.trailScale > 0, "WindParticleRenderer: invalid trail scale")
        let w = max(Int(drawable.width * Self.trailScale), 16)
        let h = max(Int(drawable.height * Self.trailScale), 16)
        if let t = trailFront, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                        mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        trailFront = device.makeTexture(descriptor: d)
        trailBack = device.makeTexture(descriptor: d)
    }

    // MARK: - particles

    /// Reseed the pool across the view. Called on a size change and whenever the field set first arrives.
    private func seedParticles() {
        assert(viewSize.width > 0, "WindParticleRenderer: seeding with no view size")
        assert(Self.maxParticles > 0, "WindParticleRenderer: empty particle pool")
        particles.removeAll(keepingCapacity: true)
        for _ in 0..<Self.maxParticles {                        // bounded (rule 2)
            particles.append(randomParticle())
        }
    }

    private func randomParticle() -> Particle {
        var p = Particle()
        p.x = Float.random(in: 0...Float(max(viewSize.width, 1)), using: &rng)
        p.y = Float.random(in: 0...Float(max(viewSize.height, 1)), using: &rng)
        p.prevX = p.x
        p.prevY = p.y
        // Stagger the lifetimes so the field does not visibly blink as a whole cohort respawns together.
        p.age = Float.random(in: 0...Self.baseLifeFrames, using: &rng)
        p.life = Self.baseLifeFrames * Float.random(in: 0.6...1.4, using: &rng)
        return p
    }

    /// Advance every particle one step and build this frame's segment vertices.
    private func step(dt: Float, camera: WindCamera, field: WindField) {
        assert(dt > 0, "WindParticleRenderer: non-positive timestep")
        assert(!particles.isEmpty, "WindParticleRenderer: stepping an unseeded pool")
        vertices.removeAll(keepingCapacity: true)
        let scale = Self.renderSpeedScale(zoom: camera.zoom)
        let w = Float(viewSize.width), h = Float(viewSize.height)
        for i in particles.indices {                            // bounded by the pool size (rule 2)
            var p = particles[i]
            p.age += 1
            let point = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
            guard p.age < p.life, p.x >= -8, p.y >= -8, p.x <= w + 8, p.y <= h + 8,
                  let ll = camera.transform.toLonLat(point),
                  let wind = field.sample(lat: ll.lat, lon: ll.lon) else {
                particles[i] = randomParticle()
                continue
            }
            let kt = (wind.x * wind.x + wind.y * wind.y).squareRoot() * WindField.mpsToKt
            let vel = camera.transform.screenVelocity(u: Double(wind.x), v: Double(wind.y),
                                                      atLat: ll.lat, speedPoints: Double(kt * scale))
            p.prevX = p.x
            p.prevY = p.y
            p.x += Float(vel.dx) * dt
            p.y += Float(vel.dy) * dt
            p.speedKt = kt
            particles[i] = p
            appendSegment(p)
        }
    }

    /// Points per second per knot, mildly scaled by zoom so the flow reads at both continental and
    /// terminal scales without becoming either a crawl or a blur.
    static func renderSpeedScale(zoom: Double) -> Float {
        assert(zoom.isFinite, "WindParticleRenderer: non-finite zoom")
        assert(baseSpeedScale > 0, "WindParticleRenderer: non-positive base speed")
        let z = min(max(zoom, 2), 14)
        let factor = pow(2.0, (z - 6.0) * 0.16)
        return Float(min(max(baseSpeedScale * factor, 1.5), 5.0))
    }

    /// Points per second per knot at zoom 6. Calibrated from what the eye can actually follow: a 30 kt wind
    /// crosses about 70 points a second, which reads as a purposeful drift, while a 120 kt jet core rips
    /// across the screen the way it should. An earlier value four times smaller moved light air a fifth of a
    /// point per frame — mathematically in motion, visually frozen.
    static let baseSpeedScale = 2.4

    /// One quad from the particle's previous point to its current one. The head is brighter than the tail,
    /// which is what makes a streak read as travelling in a direction rather than just sitting there.
    private func appendSegment(_ p: Particle) {
        assert(vertices.count + 6 <= Self.maxParticles * 6, "WindParticleRenderer: vertex overflow")
        assert(p.speedKt >= 0, "WindParticleRenderer: negative particle speed")
        let dx = p.x - p.prevX, dy = p.y - p.prevY
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.001 else { return }                     // genuinely calm: no direction to draw along
        // Stretch the drawn streak back to the minimum dash length along the travel direction, so light air
        // is visible as slow motion instead of vanishing below the rasteriser's sample grid.
        let drawn = max(len, Self.minSegmentLength)
        let ux = dx / len, uy = dy / len
        let tailX = p.x - ux * drawn, tailY = p.y - uy * drawn
        let half = Self.segmentWidth / 2
        let nx = -uy * half, ny = ux * half
        let rgb = ramp.rgb(kt: p.speedKt)
        // Fade in at birth and out at death so respawns do not pop.
        let lifeFade = min(min(p.age, 12) / 12, max(0, (p.life - p.age) / 24))
        let a = ramp.alpha(kt: p.speedKt) * min(1, max(0, lifeFade))
        let head = SIMD4<Float>(rgb, a)
        let tail = SIMD4<Float>(rgb, a * 0.45)
        let t0 = SIMD2<Float>(tailX + nx, tailY + ny)
        let t1 = SIMD2<Float>(tailX - nx, tailY - ny)
        let h0 = SIMD2<Float>(p.x + nx, p.y + ny)
        let h1 = SIMD2<Float>(p.x - nx, p.y - ny)
        vertices.append(WindSegVertex(position: t0, color: tail))
        vertices.append(WindSegVertex(position: t1, color: tail))
        vertices.append(WindSegVertex(position: h0, color: head))
        vertices.append(WindSegVertex(position: h0, color: head))
        vertices.append(WindSegVertex(position: t1, color: tail))
        vertices.append(WindSegVertex(position: h1, color: head))
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = view.bounds.size
        makeTrailTextures(drawable: size)
        lastCamera = nil                     // the old motion delta means nothing at a new size
        if viewSize.width > 1 { seedParticles() }
    }

    func draw(in view: MTKView) {
        guard let field = fieldSet?.field(level), let camera = cameraProvider?() else { return }
        let alpha = Self.spanAlpha(camera.lonSpan)
        guard alpha > 0.01 else { return }
        if viewSize != view.bounds.size {
            viewSize = view.bounds.size
            seedParticles()
        }
        guard viewSize.width > 1, !particles.isEmpty else { return }
        makeTrailTextures(drawable: view.drawableSize)
        let dt = frameDelta()
        step(dt: dt, camera: camera, field: field)
        let motion = lastCamera.flatMap { camera.transform.delta(from: $0) } ?? .identity
        lastCamera = camera.transform
        encode(view: view, motion: motion, alpha: Float(alpha))
    }

    /// Wall-clock step, clamped so a stall (a tab switch, a style reload) cannot teleport the whole field.
    private func frameDelta() -> Float {
        let now = CACurrentMediaTime()
        defer { lastFrameTime = now }
        assert(now > 0, "WindParticleRenderer: bad media time")
        guard lastFrameTime > 0 else { return 1.0 / 30 }
        let dt = now - lastFrameTime
        assert(dt >= 0, "WindParticleRenderer: time ran backwards")
        return Float(min(max(dt, 1.0 / 120), 1.0 / 15))
    }

    /// Layer opacity from the visible span: full where one affine describes the screen well, fading to
    /// nothing as the globe's curvature takes over.
    static func spanAlpha(_ lonSpan: Double) -> Double {
        assert(cutoffSpan > fullAlphaSpan, "WindParticleRenderer: inverted span gate")
        assert(lonSpan.isFinite, "WindParticleRenderer: non-finite span")
        guard lonSpan > fullAlphaSpan else { return 1 }
        guard lonSpan < cutoffSpan else { return 0 }
        return (cutoffSpan - lonSpan) / (cutoffSpan - fullAlphaSpan)
    }

    // MARK: - encoding

    private func encode(view: MTKView, motion: CGAffineTransform, alpha: Float) {
        guard let drawable = view.currentDrawable,
              let front = trailFront, let back = trailBack,
              let buffer = vertexBuffers.isEmpty ? nil : vertexBuffers[bufferIndex],
              let command = queue.makeCommandBuffer() else { return }
        inflight.wait()
        command.addCompletedHandler { [inflight] _ in inflight.signal() }
        bufferIndex = (bufferIndex + 1) % max(vertexBuffers.count, 1)
        if !vertices.isEmpty {
            let bytes = min(vertices.count * MemoryLayout<WindSegVertex>.stride, buffer.length)
            vertices.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.contents().copyMemory(from: base, byteCount: bytes)
            }
        }
        encodeFade(command, from: front, into: back, motion: motion)
        encodeSegments(command, into: back, buffer: buffer, alpha: 1, load: .load)
        encodeComposite(command, texture: back, view: view, buffer: buffer, alpha: alpha)
        trailFront = back
        trailBack = front
        command.present(drawable)
        command.commit()
    }

    private func encodeFade(_ command: MTLCommandBuffer, from src: MTLTexture, into dst: MTLTexture,
                            motion: CGAffineTransform) {
        guard let pipeline = fadePipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = WindFadeUniforms(uvTransform: Self.uvTransform(motion: motion, size: viewSize),
                                fade: Self.trailFade)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<WindFadeUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func encodeSegments(_ command: MTLCommandBuffer, into dst: MTLTexture, buffer: MTLBuffer,
                                alpha: Float, load: MTLLoadAction) {
        guard let pipeline = segmentPipeline, !vertices.isEmpty else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encodeDraw(enc, pipeline: pipeline, buffer: buffer, alpha: alpha)
    }

    /// Composite the accumulated trails over the map, then redraw this frame's segments at full resolution
    /// so the leading edge of each streak stays crisp against the half-res glow behind it.
    private func encodeComposite(_ command: MTLCommandBuffer, texture: MTLTexture, view: MTKView,
                                 buffer: MTLBuffer, alpha: Float) {
        guard let composite = compositePipeline, let pass = view.currentRenderPassDescriptor else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = WindSegUniforms(viewportSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                               alpha: alpha)
        enc.setRenderPipelineState(composite)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let segments = segmentPipeline, !vertices.isEmpty {
            enc.setRenderPipelineState(segments)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WindSegUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        enc.endEncoding()
    }

    private func encodeDraw(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
                            buffer: MTLBuffer, alpha: Float) {
        assert(!vertices.isEmpty, "WindParticleRenderer: drawing an empty vertex list")
        assert(vertices.count % 3 == 0, "WindParticleRenderer: vertex count is not whole triangles")
        var u = WindSegUniforms(viewportSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                               alpha: alpha)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<WindSegUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        enc.endEncoding()
    }

    /// The fade pass samples the OLD trail texture at the position each destination pixel occupied last
    /// frame, so the transform handed to the shader is the inverse of the map's motion, expressed in uv.
    static func uvTransform(motion: CGAffineTransform, size: CGSize) -> simd_float3x3 {
        assert(size.width >= 0 && size.height >= 0, "WindParticleRenderer: negative view size")
        let w = Float(max(size.width, 1)), h = Float(max(size.height, 1))
        guard size.width > 0, size.height > 0, abs(motion.a * motion.d - motion.b * motion.c) > 1e-9 else {
            return matrix_identity_float3x3
        }
        let inv = motion.inverted()
        // uv -> pixels -> inverse motion -> uv. Column-major, as Metal expects.
        let a = Float(inv.a), b = Float(inv.b), c = Float(inv.c), d = Float(inv.d)
        let tx = Float(inv.tx), ty = Float(inv.ty)
        return simd_float3x3(columns: (SIMD3<Float>(a, b * w / h, 0),
                                       SIMD3<Float>(c * h / w, d, 0),
                                       SIMD3<Float>(tx / w, ty / h, 1)))
    }
}
