import Metal
import MetalKit
import simd
#if APPEX
import CoreImage
import QuartzCore
#endif

/// Draws each frame: Matrix rain + optionally a rotating 3D object.
///
/// Two rain presentations via different code paths per variant:
///   - "matrix_rain" (2D): flat screen-space overlay
///     (`MatrixRainSimulation`), never with the object.
///   - "matrix3d_object"/"matrix3d_rain": volumetric 3D rain
///     (`WorldRain`) -- camera-facing billboards with real world depth,
///     additive and depth-tested against the object (rain occluded behind
///     the object is hidden). Only "matrix3d_object" also shows the
///     rotating object.
///
/// Physics glyphs (bouncing/sliding on the object, `PhysicsField`) land
/// wherever a rain stream hits the object's surface (collision query via
/// `GpuRaycaster`), only for "matrix3d_object" (the object must be visible
/// for there to be anything to land on).
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    /// Mirrors the MTKView's sampleCount (MSAA) -- pipelines built later
    /// (e.g. mesh pipelines in `makeMeshPipeline`, on model load, long after
    /// init) need this too, but don't have the original `mtkView` in scope.
    private let sampleCount: Int

    private let glyphPipeline: MTLRenderPipelineState
    private let glyph3DPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let depthOffState: MTLDepthStencilState
    private let depthReadState: MTLDepthStencilState

    private var atlas: GlyphAtlas!
    private var rain2D: MatrixRainSimulation!
    private var worldRain: WorldRain?
    private var worldRainColumns = -1
    private var worldRainSizePercent = -1

    private var teapot: TeapotMesh?
    private var meshPipelinePlain: MTLRenderPipelineState?
    private var meshPipelineColored: MTLRenderPipelineState?
    private var meshPipelineChrome: MTLRenderPipelineState?
    private var meshPipelineTextured: MTLRenderPipelineState?
    private var meshPipelinePBR: MTLRenderPipelineState?
    /// 1x1 stand-in textures for emissive/normal when an imported model has
    /// none -- Metal needs a validly bound texture for every declared
    /// texture argument, even when `PBRFlags` makes the fragment shader
    /// ignore its sampling result.
    private lazy var dummyBlackTexture: MTLTexture? = Self.makeSolidTexture(device: device, rgba: (0, 0, 0, 255))
    private lazy var dummyNormalTexture: MTLTexture? = Self.makeSolidTexture(device: device, rgba: (128, 128, 255, 255))

    private static func makeSolidTexture(device: MTLDevice, rgba: (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let pixel: [UInt8] = [rgba.0, rgba.1, rgba.2, rgba.3]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: pixel, bytesPerRow: 4)
        return texture
    }

    private var raycaster: GpuRaycaster?
    private var physicsField: PhysicsField?
    private var physicsMaxGlyphs = -1

    private var glyphVertexBuffer: MTLBuffer?
    private var glyphVertexCapacity = 0
    private var glyph3DInstanceBuffer: MTLBuffer?
    private var glyph3DInstanceCapacity = 0

    private var lastTimestamp: CFTimeInterval = 0
    private var elapsed: Float = 0
    let isPreview: Bool
    var screenID: Int32?

    #if APPEX
    /// ViewBridge does not composite CAMetalLayer/MTKView reliably — publish
    /// each frame as a CGImage onto this AppKit layer instead.
    weak var bridgeLayer: CALayer?
    /// Also deliver frames for AppKit `draw(_:)` remoting.
    var onBridgeFrame: ((CGImage) -> Void)?
    private let ciContext: CIContext
    private var bridgePublishBusy = false
    private var didLogBridgePublish = false
    /// Stable copy of the drawable — reading `drawable.texture` after `present`
    /// yields undefined/black contents.
    private var bridgeCopyTexture: MTLTexture?
    #endif

    private var currentModelID = ""
    private var currentCustomText = ""
    private var currentGlbPath = ""
    private var currentUsdzPath = ""
    private var currentVariant = ""
    private var frameCount = 0

    // MARK: - Diagnostics for the sporadic black screen
    private static let drawLog = MeshAtlas.makeLogger(tag: "draw")
    private static let lifecycleLog = MeshAtlas.makeLogger(tag: "lifecycle")
    private static var instanceCounter = 0
    private let instanceID: Int
    private var didLogFirstFrame = false
    private var consecutiveDrawFailures = 0
    private var didLogStuckWarning = false
    private let initTime = Date()

    /// Suspected cause of the sporadic black screen: the same
    /// legacyScreenSaver process gets reused across MANY activation cycles
    /// (with a very short idle interval, every ~60-65s) instead of being
    /// restarted. If an old Renderer/view instance is NOT released properly
    /// between cycles (a retain cycle), Metal resources (pipelines, buffers,
    /// textures) accumulate in the same process until eventually a cycle
    /// fails -- without the individual failed cycle itself showing any
    /// error. deinit should appear for EVERY previous instance at the
    /// latest shortly after the next cycle; if it's missing, that's the
    /// evidence for exactly this leak.

    struct SceneUniforms {
        var mvp: simd_float4x4
        var vp: simd_float4x4
        var model: simd_float4x4
    }

    struct MeshColorUniforms {
        var albedo: SIMD3<Float>
        var pad: Float = 0
    }

    /// Int32 instead of Bool: guarantees the same 4-byte layout as Metal's
    /// `int` on both sides of `setFragmentBytes` -- a Swift `Bool` inside a
    /// MemoryLayout tuple isn't ABI-guaranteed to match exactly.
    struct PBRFlags {
        var hasEmissive: Int32
        var hasNormalMap: Int32
    }

    init?(mtkView: MTKView, isPreview: Bool, screenID: Int32?, glyphDownscaleFactor: Float = 1.0) {
        // Diagnostics for the sporadic black screen on the real lock
        // screen: any `return nil` here leaves the view drawing NOTHING for
        // the entire session, with no delegate -- no retry. Without
        // logging, impossible to distinguish this from a model-loading
        // problem.
        let renderLog = MeshAtlas.makeLogger(tag: "renderer")
        renderLog("init start: isPreview=\(isPreview) screenID=\(screenID.map(String.init) ?? "nil (all screens)") drawableSize=\(mtkView.drawableSize)")

        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice() else {
            renderLog("FAILED: no MTLDevice available")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            renderLog("FAILED: makeCommandQueue() returned nil")
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.sampleCount = mtkView.sampleCount
        self.isPreview = isPreview
        self.screenID = screenID
        self.instanceID = Self.instanceCounter
        Self.instanceCounter += 1
        #if APPEX
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        #endif

        let bundle = Bundle(for: Renderer.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            NSLog("[Matrix3DSaverX] Metal library could not be loaded")
            renderLog("FAILED: makeDefaultLibrary(bundle:) -- shader library not loadable")
            return nil
        }
        self.library = library

        let glyphDescriptor = MTLRenderPipelineDescriptor()
        glyphDescriptor.vertexFunction = library.makeFunction(name: "glyph2d_vs")
        glyphDescriptor.fragmentFunction = library.makeFunction(name: "glyph_fs")
        if let attachment = glyphDescriptor.colorAttachments[0] {
            attachment.pixelFormat = mtkView.colorPixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        glyphDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        glyphDescriptor.rasterSampleCount = mtkView.sampleCount
        guard let glyphPipeline = try? device.makeRenderPipelineState(descriptor: glyphDescriptor) else {
            NSLog("[Matrix3DSaverX] Glyph pipeline failed")
            renderLog("FAILED: makeRenderPipelineState(glyphDescriptor) -- glyph2d_vs/glyph_fs")
            return nil
        }
        self.glyphPipeline = glyphPipeline

        // Volumetric 3D rain: purely additive (not alpha-blended) --
        // overlapping, transparent billboards accumulate into a dense
        // cascade instead of occluding each other.
        let glyph3DDescriptor = MTLRenderPipelineDescriptor()
        glyph3DDescriptor.vertexFunction = library.makeFunction(name: "glyph3d_vs")
        glyph3DDescriptor.fragmentFunction = library.makeFunction(name: "glyph_fs")
        if let attachment = glyph3DDescriptor.colorAttachments[0] {
            attachment.pixelFormat = mtkView.colorPixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
        glyph3DDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        glyph3DDescriptor.rasterSampleCount = mtkView.sampleCount
        guard let glyph3DPipeline = try? device.makeRenderPipelineState(descriptor: glyph3DDescriptor) else {
            NSLog("[Matrix3DSaverX] 3D glyph pipeline failed")
            renderLog("FAILED: makeRenderPipelineState(glyph3DDescriptor) -- glyph3d_vs/glyph_fs")
            return nil
        }
        self.glyph3DPipeline = glyph3DPipeline

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            renderLog("FAILED: makeDepthStencilState(depthDescriptor)")
            return nil
        }
        self.depthState = depthState

        let depthOffDescriptor = MTLDepthStencilDescriptor()
        depthOffDescriptor.depthCompareFunction = .always
        depthOffDescriptor.isDepthWriteEnabled = false
        guard let depthOffState = device.makeDepthStencilState(descriptor: depthOffDescriptor) else {
            renderLog("FAILED: makeDepthStencilState(depthOffDescriptor)")
            return nil
        }
        self.depthOffState = depthOffState

        // READ the depth test (against the object), but don't write it ->
        // rain billboards don't occlude each other (additive, order-free),
        // but are correctly hidden behind the object.
        let depthReadDescriptor = MTLDepthStencilDescriptor()
        depthReadDescriptor.depthCompareFunction = .less
        depthReadDescriptor.isDepthWriteEnabled = false
        guard let depthReadState = device.makeDepthStencilState(descriptor: depthReadDescriptor) else {
            renderLog("FAILED: makeDepthStencilState(depthReadDescriptor)")
            return nil
        }
        self.depthReadState = depthReadState

        super.init()

        // Glyph size in raster pixels: base value in points x display scale.
        // Metal/the drawable works in pixels -- without this factor,
        // glyphs on a Retina screen (2x/3x, e.g. the built-in display) would
        // look half or a third the size compared to a 1x monitor.
        //
        // `glyphDownscaleFactor` (< 1 only under APPEX, when
        // `metalRenderSize` has shrunk the Metal target relative to the
        // real screen) exactly compensates for that shrink: without it,
        // glyphs would get bigger after upscaling to the real screen the
        // higher the native resolution is (the stronger the downscale) --
        // different screens would then have DIFFERENT optical glyph sizes
        // instead of a consistent look everywhere.
        let backingScale = ScreenRegistry.backingScale(for: mtkView)
        // Base values deliberately chosen a bit smaller so individual
        // glyphs don't look oversized at typical screen sizes.
        let fontSize = CGFloat((isPreview ? 12.1 : 14.52) * 1.21875 * backingScale * glyphDownscaleFactor)
        guard let atlas = GlyphAtlas(device: device, fontSize: fontSize) else {
            NSLog("[Matrix3DSaverX] Glyph atlas failed")
            renderLog("FAILED: GlyphAtlas(device:fontSize:) fontSize=\(fontSize) backingScale=\(backingScale)")
            return nil
        }
        self.atlas = atlas
        let size = mtkView.drawableSize
        self.rain2D = MatrixRainSimulation(
            width: Float(max(size.width, 1)), height: Float(max(size.height, 1)),
            preview: isPreview, atlas: atlas
        )

        currentVariant = Defaults.readVariant(screenID: screenID)
        loadModel(ModelRegistry.readModelID(screenID: screenID))
        renderLog("init SUCCEEDED (model '\(currentModelID)', variant '\(currentVariant)')")
    }

    // MARK: - Load model

    private func loadModel(_ modelID: String) {
        // File log instead of just NSLog: for problems with runtime models
        // (GLB/USDZ) in the sandboxed preview, ~/Library/Logs inside the
        // container is the only conveniently viewable channel.
        let log = MeshAtlas.makeLogger(tag: "model")
        let t0 = Date()
        guard let url = ModelRegistry.objURL(for: modelID, screenID: screenID) else {
            log("Model resource not found: \(modelID)")
            NSLog("[Matrix3DSaverX] Model resource not found: \(modelID)")
            teapot = nil
            currentModelID = modelID
            return
        }
        let t1 = Date()
        guard let mesh = TeapotMesh.cached(device: device, resourceURL: url) else {
            log("Model could not be loaded: \(modelID) (\(url.lastPathComponent))")
            NSLog("[Matrix3DSaverX] Model could not be loaded: \(modelID)")
            teapot = nil
            currentModelID = modelID
            return
        }
        log(String(format: "Model '%@' loaded: lookup %.2fs, mesh load %.2fs (%@)",
                   modelID, t1.timeIntervalSince(t0), Date().timeIntervalSince(t1), url.lastPathComponent))
        teapot = mesh
        buildMeshPipelines(for: mesh)
        currentModelID = modelID
        currentCustomText = Defaults.readCustomText(screenID: screenID)
        currentGlbPath = Defaults.readCustomGlbPath(screenID: screenID)
        currentUsdzPath = Defaults.readCustomUsdzPath(screenID: screenID)
        // Physics collision is tied to whichever mesh is loaded -- rebuild
        // on model change, otherwise glyphs would be tested against the old
        // object. The physics state itself is deliberately dropped (glyphs
        // on a logo don't meaningfully land on the new teapot).
        raycaster = GpuRaycaster(device: device, mesh: mesh)
        physicsField = nil
        physicsMaxGlyphs = -1
    }

    private func makeMeshPipeline(vertexFn: String, fragmentFn: String, vertexDescriptor: MTLVertexDescriptor, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexFn)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFn)
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = sampleCount
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func buildMeshPipelines(for mesh: TeapotMesh) {
        let colorFormat: MTLPixelFormat = .bgra8Unorm
        let depthFormat: MTLPixelFormat = .depth32Float
        meshPipelinePlain = makeMeshPipeline(vertexFn: "mesh_vs", fragmentFn: "mesh_fs", vertexDescriptor: mesh.vertexDescriptor, colorFormat: colorFormat, depthFormat: depthFormat)
        meshPipelineColored = makeMeshPipeline(vertexFn: "mesh_vs", fragmentFn: "mesh_col_fs", vertexDescriptor: mesh.vertexDescriptor, colorFormat: colorFormat, depthFormat: depthFormat)
        meshPipelineChrome = makeMeshPipeline(vertexFn: "mesh_vs", fragmentFn: "mesh_chrome_fs", vertexDescriptor: mesh.vertexDescriptor, colorFormat: colorFormat, depthFormat: depthFormat)
        if mesh.hasTexCoords {
            meshPipelineTextured = makeMeshPipeline(vertexFn: "mesh_tex_vs", fragmentFn: "mesh_tex_fs", vertexDescriptor: mesh.vertexDescriptor, colorFormat: colorFormat, depthFormat: depthFormat)
            // Can fail (nil) if tangent generation didn't take for this
            // model (see the TeapotMesh.hasTangentNormalMapping comment) --
            // the draw loop then automatically falls back to
            // meshPipelineTextured (plain BaseColor, no PBR).
            meshPipelinePBR = makeMeshPipeline(vertexFn: "mesh_pbr_vs", fragmentFn: "mesh_pbr_fs", vertexDescriptor: mesh.vertexDescriptor, colorFormat: colorFormat, depthFormat: depthFormat)
        } else {
            meshPipelineTextured = nil
            meshPipelinePBR = nil
        }
    }

    // MARK: - Poll settings on a throttled cadence

    private func refreshSettingsIfNeeded() {
        guard frameCount % 10 == 0 else { return }
        let variant = Defaults.readVariant(screenID: screenID)
        if variant != currentVariant {
            currentVariant = variant
        }
        let modelID = ModelRegistry.readModelID(screenID: screenID)
        if modelID != currentModelID {
            loadModel(modelID)
        } else if modelID == ModelRegistry.textModelID && Defaults.readCustomText(screenID: screenID) != currentCustomText {
            // Same model ("custom 3D text"), but the text changed --
            // regenerate instead of relying on the model-change branch
            // above (which only fires on ID changes, not content changes
            // of the same model).
            loadModel(modelID)
        } else if modelID == ModelRegistry.glbModelID && Defaults.readCustomGlbPath(screenID: screenID) != currentGlbPath {
            // Same logic for a newly chosen GLB/USDZ file.
            loadModel(modelID)
        } else if modelID == ModelRegistry.usdzModelID && Defaults.readCustomUsdzPath(screenID: screenID) != currentUsdzPath {
            loadModel(modelID)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let w = Float(max(size.width, 1)), h = Float(max(size.height, 1))
        rain2D?.resize(width: w, height: h)
        worldRain?.resize(width: w, height: h)
        physicsField?.resize(width: w, height: h)
    }

    private func measuredDt() -> Float {
        #if APPEX
        // Offscreen MTK + CI publish makes wall-clock dt jumpy; use a stable step
        // so rain/spin stay smooth even when visual frames are dropped. Must
        // match `enableInternalDisplayLink`'s preferredFramesPerSecond, else
        // rain/rotation speed is wrong (too fast/slow for the actual frame rate).
        return isPreview ? (1.0 / 5.0) : (1.0 / 10.0)
        #else
        let now = CACurrentMediaTime()
        defer { lastTimestamp = now }
        if lastTimestamp <= 0 { return 1.0 / 30.0 }
        return Float(min(0.1, max(0.0, now - lastTimestamp)))
        #endif
    }

    /// Needed for "matrix3d_object"/"matrix3d_rain" (volumetric rain);
    /// creates a new `WorldRain` when needed, if size/stream count/object
    /// depth have changed.
    private func ensureWorldRain(width: Float, height: Float, objectZ: Float) -> WorldRain {
        let columns = Defaults.effectiveRainStreams(preview: isPreview, screenID: screenID)
        let sizePercent = Defaults.readGlyphSizePercent(screenID: screenID)
        if let existing = worldRain, worldRainColumns == columns, worldRainSizePercent == sizePercent {
            existing.resize(width: width, height: height)
            existing.setObjectZ(objectZ)
            return existing
        }
        let fresh = WorldRain(
            width: width, height: height, preview: isPreview, objectZ: objectZ,
            atlas: atlas, columns: columns, sizeScale: Float(sizePercent) / 100.0
        )
        worldRain = fresh
        worldRainColumns = columns
        worldRainSizePercent = sizePercent
        return fresh
    }

    /// Only when the object is visible ("matrix3d_object") -- physics
    /// glyphs land on its surface, with no object there's nothing to hit.
    private func ensurePhysicsField(width: Float, height: Float) -> PhysicsField? {
        let maxGlyphs = Defaults.effectivePhysicsGlyphs(preview: isPreview, screenID: screenID)
        guard maxGlyphs > 0, let rain = worldRain else {
            physicsField = nil
            physicsMaxGlyphs = maxGlyphs
            return nil
        }
        // Slightly bigger than the background rain, so the impact stands out.
        let scale: Float = 1.15
        let halfW = rain.glyphHalfW * scale
        let halfH = rain.glyphHalfH * scale
        if let existing = physicsField, physicsMaxGlyphs == maxGlyphs {
            existing.resize(width: width, height: height)
            existing.setGlyphSize(halfW: halfW, halfH: halfH)
            return existing
        }
        let fresh = PhysicsField(
            width: width, height: height, preview: isPreview,
            glyphHalfW: halfW, glyphHalfH: halfH,
            maxGlyphs: maxGlyphs
        )
        physicsField = fresh
        physicsMaxGlyphs = maxGlyphs
        return fresh
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            // Diagnostics for the sporadic black screen: a single hiccup
            // (currentDrawable etc. briefly nil) is normal Metal behavior
            // and self-healing -- only a LONGER streak (here: ~2s at 30fps)
            // indicates an actual hang that would leave the screen
            // permanently black.
            consecutiveDrawFailures += 1
            if consecutiveDrawFailures == 60 && !didLogStuckWarning {
                didLogStuckWarning = true
                Self.drawLog("WARNING: no valid drawable/renderPassDescriptor/commandBuffer for \(consecutiveDrawFailures) frames -- screen stays black as long as this persists (drawableSize=\(view.drawableSize))")
            }
            return
        }
        if consecutiveDrawFailures > 0 {
            Self.drawLog("recovered after \(consecutiveDrawFailures) failed frame(s)")
        }
        consecutiveDrawFailures = 0
        didLogStuckWarning = false

        if !didLogFirstFrame {
            didLogFirstFrame = true
            Self.drawLog(String(format: "first frame drawn, %.2fs after renderer init (drawableSize=%@)", Date().timeIntervalSince(initTime), "\(view.drawableSize)"))
        }

        frameCount += 1
        refreshSettingsIfNeeded()

        let speedPercent = Defaults.readSimSpeedPercent(screenID: screenID)
        let dt = measuredDt() * (Float(speedPercent) / 100.0)
        elapsed += dt

        let width = Float(view.drawableSize.width)
        let height = Float(view.drawableSize.height)
        guard width > 0, height > 0 else {
            Self.drawLog("skipped: drawableSize is \(view.drawableSize) (width/height <= 0)")
            return
        }

        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        if currentVariant == "matrix_rain" {
            drawFlatRain(encoder: encoder, dt: dt, width: width, height: height)
        } else {
            let showObject = currentVariant == "matrix3d_object"
            let objectZ = showObject ? Scene.objectZWithObject : 0.0
            let aspect = width / max(1, height)
            let proj = Scene.perspective(fovY: Scene.fovY, aspect: aspect, near: Scene.nearZ, far: Scene.farZ)
            let view4 = Scene.lookAt(eye: Scene.cameraEye, center: Scene.cameraTarget(objectZ: objectZ), up: SIMD3<Float>(0, 1, 0))
            let vp = proj * view4

            let spin = Scene.objectRotation(
                elapsed: elapsed,
                spinX: Defaults.readObjectSpinX(screenID: screenID),
                spinY: Defaults.readObjectSpinY(screenID: screenID),
                spinZ: Defaults.readObjectSpinZ(screenID: screenID)
            )
            let tilt = SIMD3<Float>(
                Float(Defaults.readObjectTiltXDeg(screenID: screenID)),
                Float(Defaults.readObjectTiltYDeg(screenID: screenID)),
                Float(Defaults.readObjectTiltZDeg(screenID: screenID))
            )

            let rain = ensureWorldRain(width: width, height: height, objectZ: objectZ)
            rain.update(dt: dt)

            var instances = rain.collectInstances()
            if showObject, let physics = ensurePhysicsField(width: width, height: height) {
                physics.update(dt: dt, objectZ: objectZ, spin: spin, tiltDegrees: tilt, raycaster: raycaster, rain: rain, atlas: atlas)
                instances.append(contentsOf: physics.collectInstances(objectZ: objectZ))
            }

            if showObject, let teapot {
                drawObject(teapot, encoder: encoder, vp: vp, objectZ: objectZ, spin: spin, tilt: tilt)
            }
            drawGlyph3DInstances(instances, encoder: encoder, vp: vp)
        }

        encoder.endEncoding()
        #if APPEX
        // Blit drawable → private texture BEFORE present; reading the drawable
        // after present is undefined and often all-black under ViewBridge.
        let src = drawable.texture
        if let dst = ensureBridgeCopyTexture(width: src.width, height: src.height),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: src,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                to: dst,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.publishBridgeFrame(texture: dst)
            }
        }
        commandBuffer.present(drawable)
        #else
        commandBuffer.present(drawable)
        #endif
        commandBuffer.commit()
    }

    #if APPEX
    private func ensureBridgeCopyTexture(width: Int, height: Int) -> MTLTexture? {
        if let existing = bridgeCopyTexture, existing.width == width, existing.height == height {
            return existing
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        bridgeCopyTexture = device.makeTexture(descriptor: desc)
        return bridgeCopyTexture
    }

    /// The drawable content (`bgra8Unorm`, not an `_srgb` format) is already
    /// gamma-encoded -- the fragment shaders/atlases consistently assume
    /// this (see `MeshAtlas.linearToSRGB`, the TeapotMesh comments on
    /// "SRGB deliberately off"). `colorSpace: NSNull()` let CoreImage pass
    /// the bytes through UNTAGGED -- the CGImage ended up with no/the wrong
    /// color space and was interpreted incorrectly when composited via
    /// ViewBridge (symptom: colors look washed out and too bright, across
    /// the whole image). Fix: explicitly tag both source AND destination as
    /// sRGB, without changing the values themselves.
    private static let bridgeColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private func publishBridgeFrame(texture: MTLTexture) {
        guard let bridgeLayer else { return }
        guard !bridgePublishBusy else { return }
        bridgePublishBusy = true

        guard texture.width > 0, texture.height > 0 else {
            bridgePublishBusy = false
            return
        }
        guard let ciImage = CIImage(mtlTexture: texture, options: [.colorSpace: Self.bridgeColorSpace]) else {
            bridgePublishBusy = false
            return
        }
        let flipped = ciImage.transformed(
            by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: ciImage.extent.height)
        )
        guard let cgImage = ciContext.createCGImage(
            flipped, from: flipped.extent, format: .BGRA8, colorSpace: Self.bridgeColorSpace
        ) else {
            bridgePublishBusy = false
            return
        }
        DispatchQueue.main.async { [weak self, weak bridgeLayer] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bridgeLayer?.contents = cgImage
            bridgeLayer?.contentsGravity = .resize
            bridgeLayer?.contentsScale = 1
            CATransaction.commit()
            self.onBridgeFrame?(cgImage)
            if !self.didLogBridgePublish {
                self.didLogBridgePublish = true
                Self.drawLog("ViewBridge: frame published (\(cgImage.width)x\(cgImage.height)) [blit+draw]")
            }
            self.bridgePublishBusy = false
        }
    }
    #endif

    private func drawFlatRain(encoder: MTLRenderCommandEncoder, dt: Float, width: Float, height: Float) {
        rain2D.update(dt: dt)
        let instances = rain2D.collectInstances()
        guard !instances.isEmpty else { return }
        uploadGlyphVertices(instances: instances, cellW: Float(atlas.cellWidth), cellH: Float(atlas.cellHeight))
        encoder.setRenderPipelineState(glyphPipeline)
        encoder.setDepthStencilState(depthOffState)
        encoder.setVertexBuffer(glyphVertexBuffer, offset: 0, index: 0)
        var screen = SIMD2<Float>(width, height)
        encoder.setVertexBytes(&screen, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: instances.count * 6)
    }

    /// Rain + physics glyphs are drawn in ONE shared instance buffer/draw
    /// call, not two separate ones: otherwise the buffer would get
    /// overwritten between recording the first draw and the second upload,
    /// before the GPU has read it (both draws share the same MTLBuffer,
    /// command encoding is only CPU-side recording).
    private func drawGlyph3DInstances(_ instances: [Glyph3DInstance], encoder: MTLRenderCommandEncoder, vp: simd_float4x4) {
        guard !instances.isEmpty else { return }
        uploadGlyph3DInstances(instances)
        encoder.setRenderPipelineState(glyph3DPipeline)
        encoder.setDepthStencilState(depthReadState)
        encoder.setVertexBuffer(glyph3DInstanceBuffer, offset: 0, index: 0)
        var vpCopy = vp
        encoder.setVertexBytes(&vpCopy, length: MemoryLayout<simd_float4x4>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
    }

    private func drawObject(_ teapot: TeapotMesh, encoder: MTLRenderCommandEncoder, vp: simd_float4x4, objectZ: Float, spin: SIMD3<Float>, tilt: SIMD3<Float>) {
        let model = Scene.objectModelMatrix(center: teapot.center, scale: teapot.scale, objectZ: objectZ, spin: spin, tiltDegrees: tilt)
        var uniforms = SceneUniforms(mvp: vp * model, vp: vp, model: model)

        encoder.setDepthStencilState(depthState)
        teapot.bindVertexBuffers(encoder)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.size, index: 2)

        if teapot.isMultiMaterial {
            for (index, kind) in teapot.submeshKinds.enumerated() {
                switch kind {
                case .pbr where meshPipelinePBR != nil && teapot.ormTexture != nil && teapot.baseColorTexture != nil:
                    bindPBRSubmesh(teapot, encoder: encoder)
                case .top where meshPipelineTextured != nil:
                    encoder.setRenderPipelineState(meshPipelineTextured!)
                    encoder.setFragmentTexture(teapot.baseColorTexture, index: 1)
                case .chrome:
                    guard let pipeline = meshPipelineChrome else { continue }
                    encoder.setRenderPipelineState(pipeline)
                    var color = MeshColorUniforms(albedo: teapot.submeshColors[index] ?? SIMD3<Float>(0.96, 0.97, 0.99))
                    encoder.setFragmentBytes(&color, length: MemoryLayout<MeshColorUniforms>.size, index: 3)
                default:
                    guard let pipeline = meshPipelineColored else { continue }
                    encoder.setRenderPipelineState(pipeline)
                    var color = MeshColorUniforms(albedo: teapot.submeshColors[index] ?? SIMD3<Float>(0.5, 0.5, 0.5))
                    encoder.setFragmentBytes(&color, length: MemoryLayout<MeshColorUniforms>.size, index: 3)
                }
                teapot.drawSubmesh(index, encoder: encoder)
            }
        } else if teapot.submeshKinds.first == .pbr, meshPipelinePBR != nil, teapot.ormTexture != nil, teapot.baseColorTexture != nil {
            bindPBRSubmesh(teapot, encoder: encoder)
            teapot.drawSubmesh(0, encoder: encoder)
        } else if let texturedPipeline = meshPipelineTextured, teapot.baseColorTexture != nil {
            encoder.setRenderPipelineState(texturedPipeline)
            encoder.setFragmentTexture(teapot.baseColorTexture, index: 1)
            teapot.drawSubmesh(0, encoder: encoder)
        } else if let plainPipeline = meshPipelinePlain {
            encoder.setRenderPipelineState(plainPipeline)
            teapot.drawSubmesh(0, encoder: encoder)
        }
    }

    /// Binds the pipeline + all four textures for a `.pbr` submesh. Caller
    /// must have already checked `meshPipelinePBR`/`ormTexture`/
    /// `baseColorTexture` for non-nil.
    private func bindPBRSubmesh(_ teapot: TeapotMesh, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(meshPipelinePBR!)
        encoder.setFragmentTexture(teapot.baseColorTexture, index: 1)
        encoder.setFragmentTexture(teapot.ormTexture, index: 2)
        encoder.setFragmentTexture(teapot.emissiveTexture ?? dummyBlackTexture, index: 3)
        encoder.setFragmentTexture(teapot.normalTexture ?? dummyNormalTexture, index: 4)
        var flags = PBRFlags(
            hasEmissive: teapot.emissiveTexture != nil ? 1 : 0,
            hasNormalMap: teapot.hasTangentNormalMapping ? 1 : 0
        )
        encoder.setFragmentBytes(&flags, length: MemoryLayout<PBRFlags>.size, index: 3)
    }

    private func uploadGlyphVertices(instances: [GlyphInstance], cellW: Float, cellH: Float) {
        var verts: [Float] = []
        verts.reserveCapacity(instances.count * 6 * 8)
        for inst in instances {
            let x0 = inst.x, y0 = inst.y
            let x1 = x0 + cellW, y1 = y0 + cellH
            let color: [Float] = [inst.r, inst.g, inst.b, inst.a]
            let quad: [(Float, Float, Float, Float)] = [
                (x0, y0, inst.u0, inst.v0),
                (x1, y0, inst.u1, inst.v0),
                (x1, y1, inst.u1, inst.v1),
                (x0, y0, inst.u0, inst.v0),
                (x1, y1, inst.u1, inst.v1),
                (x0, y1, inst.u0, inst.v1),
            ]
            for (px, py, u, v) in quad {
                verts.append(contentsOf: [px, py, u, v])
                verts.append(contentsOf: color)
            }
        }
        let byteCount = verts.count * MemoryLayout<Float>.size
        if glyphVertexBuffer == nil || glyphVertexCapacity < byteCount {
            glyphVertexCapacity = max(byteCount, glyphVertexCapacity > 0 ? glyphVertexCapacity * 2 : 1 << 18)
            glyphVertexBuffer = device.makeBuffer(length: glyphVertexCapacity, options: .storageModeShared)
        }
        guard let buffer = glyphVertexBuffer else { return }
        memcpy(buffer.contents(), verts, byteCount)
    }

    private func uploadGlyph3DInstances(_ instances: [Glyph3DInstance]) {
        let byteCount = instances.count * MemoryLayout<Glyph3DInstance>.stride
        if glyph3DInstanceBuffer == nil || glyph3DInstanceCapacity < byteCount {
            glyph3DInstanceCapacity = max(byteCount, glyph3DInstanceCapacity > 0 ? glyph3DInstanceCapacity * 2 : 1 << 16)
            glyph3DInstanceBuffer = device.makeBuffer(length: glyph3DInstanceCapacity, options: .storageModeShared)
        }
        guard let buffer = glyph3DInstanceBuffer else { return }
        instances.withUnsafeBytes { raw in
            memcpy(buffer.contents(), raw.baseAddress, byteCount)
        }
    }
}
