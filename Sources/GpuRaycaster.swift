import Metal
import simd

/// Result of a ray hit against the object (world coordinates).
struct RayHit {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var distance: Float
}

/// Batch raycasts against the currently loaded 3D object via a Metal
/// compute shader.
///
/// Filled once per frame (`beginFrame`) and then served with any number of
/// screen-point or world-ray queries -- each query kind dispatches its own
/// compute pass (`raycast_kernel` in `Shaders/Shaders.metal`), waited on
/// synchronously (small batches, <=2048 rays, which is cheap enough for
/// real-time per-frame physics).
final class GpuRaycaster {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let queue: MTLCommandQueue
    private let triangleBuffer: MTLBuffer
    private let triCount: Int
    private let boundsMin: SIMD3<Float>
    private let boundsMax: SIMD3<Float>

    private var queryBuffer: MTLBuffer
    private var hitBuffer: MTLBuffer
    private var queryCapacity: Int

    private static let maxRaycasts = 2048

    private struct RayQueryGPU {
        var origin: SIMD4<Float>
        var direction: SIMD4<Float>
    }
    private struct RayHitGPU {
        var position: SIMD4<Float>
        var normal: SIMD4<Float>
        var distance: Float
        var valid: Float
    }
    private struct SceneParams {
        var triCount: UInt32
        var queryCount: UInt32
        var pad: SIMD2<Float>
        var bmin: SIMD4<Float>
        var bmax: SIMD4<Float>
    }

    private var objectZ: Float = 0
    private var spin: SIMD3<Float> = .zero
    private var tiltDegrees: SIMD3<Float> = .zero
    private var screenWidth: Float = 1
    private var screenHeight: Float = 1

    init?(device: MTLDevice, mesh: TeapotMesh) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let bundle = Bundle(for: GpuRaycaster.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle),
              let function = library.makeFunction(name: "raycast_kernel"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            NSLog("[Matrix3DSaverX] Raycast compute pipeline failed")
            return nil
        }
        self.pipeline = pipeline

        let triangles = mesh.raycastTriangles
        self.triCount = triangles.count / 3
        self.boundsMin = mesh.boundsMin
        self.boundsMax = mesh.boundsMax

        var flat: [Float] = []
        flat.reserveCapacity(triangles.count * 3)
        for v in triangles {
            flat.append(v.x); flat.append(v.y); flat.append(v.z)
        }
        guard !flat.isEmpty,
              let triBuf = device.makeBuffer(bytes: flat, length: flat.count * MemoryLayout<Float>.stride, options: .storageModeShared) else {
            return nil
        }
        self.triangleBuffer = triBuf

        self.queryCapacity = Self.maxRaycasts
        guard let qb = device.makeBuffer(length: queryCapacity * MemoryLayout<RayQueryGPU>.stride, options: .storageModeShared),
              let hb = device.makeBuffer(length: queryCapacity * MemoryLayout<RayHitGPU>.stride, options: .storageModeShared) else {
            return nil
        }
        self.queryBuffer = qb
        self.hitBuffer = hb
    }

    func beginFrame(screenWidth: Float, screenHeight: Float, objectZ: Float, spin: SIMD3<Float>, tiltDegrees: SIMD3<Float>) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.objectZ = objectZ
        self.spin = spin
        self.tiltDegrees = tiltDegrees
    }

    /// Packs integer screen coordinates into a single hash key -- used by
    /// `PhysicsField` to map `castBatch` hits back to the triggering
    /// character.
    static func packKey(_ x: Int, _ y: Int) -> Int64 {
        Int64(Int32(truncatingIfNeeded: x)) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
    }

    /// Batch raycasts for screen points (screenX, screenY), hits keyed by
    /// `packKey(Int(x), Int(y))`.
    func castBatch(_ points: [(Float, Float)]) -> [Int64: RayHit] {
        guard !points.isEmpty else { return [:] }
        var seen = Set<Int64>()
        var unique: [(Float, Float)] = []
        for p in points {
            let key = Self.packKey(Int(p.0), Int(p.1))
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(p)
            if unique.count >= Self.maxRaycasts { break }
        }
        guard !unique.isEmpty else { return [:] }

        let rot3 = Scene.rotationMatrix3x3(spin: spin, tiltDegrees: tiltDegrees)
        let shift = SIMD3<Float>(0, 0, objectZ)
        let localOriginShared = Scene.worldToLocal(Scene.cameraEye - shift, rotation3x3: rot3)

        var localOrigins: [SIMD3<Float>] = []
        var localDirs: [SIMD3<Float>] = []
        localOrigins.reserveCapacity(unique.count)
        localDirs.reserveCapacity(unique.count)
        for (sx, sy) in unique {
            let dirWorld = Scene.worldRayDirection(screenX: sx, screenY: sy, width: screenWidth, height: screenHeight, objectZ: objectZ)
            localOrigins.append(localOriginShared)
            localDirs.append(normalize(Scene.worldToLocal(dirWorld, rotation3x3: rot3)))
        }

        let hitsGPU = runLocalRays(origins: localOrigins, dirs: localDirs)
        var out: [Int64: RayHit] = [:]
        for (i, (sx, sy)) in unique.enumerated() {
            let h = hitsGPU[i]
            guard h.valid > 0.5 else { continue }
            let localPos = SIMD3<Float>(h.position.x, h.position.y, h.position.z)
            let localNormal = SIMD3<Float>(h.normal.x, h.normal.y, h.normal.z)
            let worldPos = Scene.localToWorld(localPos, rotation3x3: rot3) + shift
            let worldNormal = normalize(Scene.localToWorld(localNormal, rotation3x3: rot3))
            out[Self.packKey(Int(sx), Int(sy))] = RayHit(position: worldPos, normal: worldNormal, distance: h.distance)
        }
        return out
    }

    /// Arbitrary world rays (e.g. straight down from above) against the
    /// object. Returns hits/nil in the same order as `origins`/`directions`.
    func castWorldRays(origins: [SIMD3<Float>], directions: [SIMD3<Float>]) -> [RayHit?] {
        let n = min(origins.count, Self.maxRaycasts)
        guard n > 0 else { return [] }
        let rot3 = Scene.rotationMatrix3x3(spin: spin, tiltDegrees: tiltDegrees)
        let shift = SIMD3<Float>(0, 0, objectZ)

        var localOrigins: [SIMD3<Float>] = []
        var localDirs: [SIMD3<Float>] = []
        localOrigins.reserveCapacity(n)
        localDirs.reserveCapacity(n)
        for i in 0..<n {
            localOrigins.append(Scene.worldToLocal(origins[i] - shift, rotation3x3: rot3))
            localDirs.append(normalize(Scene.worldToLocal(directions[i], rotation3x3: rot3)))
        }

        let hitsGPU = runLocalRays(origins: localOrigins, dirs: localDirs)
        var result = [RayHit?](repeating: nil, count: n)
        for i in 0..<n {
            let h = hitsGPU[i]
            guard h.valid > 0.5 else { continue }
            let localPos = SIMD3<Float>(h.position.x, h.position.y, h.position.z)
            let localNormal = SIMD3<Float>(h.normal.x, h.normal.y, h.normal.z)
            let worldPos = Scene.localToWorld(localPos, rotation3x3: rot3) + shift
            let worldNormal = normalize(Scene.localToWorld(localNormal, rotation3x3: rot3))
            result[i] = RayHit(position: worldPos, normal: worldNormal, distance: h.distance)
        }
        return result
    }

    private func runLocalRays(origins: [SIMD3<Float>], dirs: [SIMD3<Float>]) -> [RayHitGPU] {
        let count = dirs.count
        guard count > 0 else { return [] }
        if count > queryCapacity {
            queryCapacity = count
            guard let qb = device.makeBuffer(length: queryCapacity * MemoryLayout<RayQueryGPU>.stride, options: .storageModeShared),
                  let hb = device.makeBuffer(length: queryCapacity * MemoryLayout<RayHitGPU>.stride, options: .storageModeShared) else {
                return []
            }
            queryBuffer = qb
            hitBuffer = hb
        }

        let queryPtr = queryBuffer.contents().bindMemory(to: RayQueryGPU.self, capacity: count)
        for i in 0..<count {
            queryPtr[i] = RayQueryGPU(
                origin: SIMD4<Float>(origins[i].x, origins[i].y, origins[i].z, 0),
                direction: SIMD4<Float>(dirs[i].x, dirs[i].y, dirs[i].z, 0)
            )
        }

        var scene = SceneParams(
            triCount: UInt32(triCount), queryCount: UInt32(count), pad: .zero,
            bmin: SIMD4<Float>(boundsMin.x, boundsMin.y, boundsMin.z, 0),
            bmax: SIMD4<Float>(boundsMax.x, boundsMax.y, boundsMax.z, 0)
        )
        guard let sceneBuffer = device.makeBuffer(bytes: &scene, length: MemoryLayout<SceneParams>.stride, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return []
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sceneBuffer, offset: 0, index: 0)
        encoder.setBuffer(triangleBuffer, offset: 0, index: 1)
        encoder.setBuffer(queryBuffer, offset: 0, index: 2)
        encoder.setBuffer(hitBuffer, offset: 0, index: 3)

        let threadWidth = pipeline.threadExecutionWidth
        let groups = (count + threadWidth - 1) / threadWidth
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threadWidth, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let hitPtr = hitBuffer.contents().bindMemory(to: RayHitGPU.self, capacity: count)
        return (0..<count).map { hitPtr[$0] }
    }
}
