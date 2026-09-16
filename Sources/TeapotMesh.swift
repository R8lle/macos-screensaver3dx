import Foundation
import Metal
import MetalKit
import ModelIO
import simd

/// How a submesh gets colored, recognized from the OBJ material name
/// (`chrome`/`inner`/`outer`/`top`, otherwise `outer`). `pbr` is only
/// assigned by `MeshAtlas.writeObjMtl` for imported GLB/USDZ models (real
/// pixel-for-pixel PBR shading with BaseColor/ORM/Emissive/Normal atlases
/// instead of a coarse chrome/non-chrome split).
enum SubmeshKind: String {
    case chrome, inner, outer, top, pbr

    static func classify(materialName: String?) -> SubmeshKind {
        let name = (materialName ?? "").lowercased()
        if name.contains("pbr") { return .pbr }
        if name.contains("chrome") { return .chrome }
        if name.contains("inner") { return .inner }
        if name.contains("top") { return .top }
        return .outer
    }
}

/// A loaded 3D model (default object: teapot, or one of the bundled
/// logos/spaceship). Name "TeapotMesh" deliberately kept -- a nod to the
/// classic Utah teapot as an Xcode/OpenGL test model, even though arbitrary
/// models get loaded.
///
/// Unlike the first (core) version, the vertex descriptor is NO LONGER
/// forced: ModelIO's own OBJ importer delivers the natural layout
/// (position+normal, plus texture coordinates when UV data is present) --
/// this allows textured and multi-colored multi-material models (logos,
/// spaceship), not just a single untextured mesh.
final class TeapotMesh {
    let mtkMesh: MTKMesh
    let center: SIMD3<Float>
    let scale: Float
    /// Per submesh (same order as `mtkMesh.submeshes`), the recognized kind.
    let submeshKinds: [SubmeshKind]
    /// Per submesh, the base color (Kd/baseColor), if readable.
    let submeshColors: [SIMD3<Float>?]
    /// Base color texture, if ANY material references one (for the single-
    /// material case, or "top" submeshes on multi-material models).
    let baseColorTexture: MTLTexture?
    /// Occlusion(R)/Roughness(G)/Metallic(B) -- only set for imported
    /// GLB/USDZ models (`.pbr` submesh).
    let ormTexture: MTLTexture?
    let emissiveTexture: MTLTexture?
    let normalTexture: MTLTexture?
    /// true when the mesh carries tangents AND a normal map could be
    /// loaded -- only then may the PBR shader actually apply the normal
    /// map (see tangent generation in the initializer).
    let hasTangentNormalMapping: Bool
    /// Vertex layout for pipeline creation, taken 1:1 from ModelIO.
    let vertexDescriptor: MTLVertexDescriptor
    /// Does the mesh have texture coordinates (then `mesh_tex_*` can be used)?
    let hasTexCoords: Bool
    /// Bounding box in the same (centered+scaled) space as `raycastTriangles`.
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    static let fitScale: Float = 2.15

    // MARK: - Process-wide mesh cache

    /// Cache of loaded meshes keyed by (path, mtime). Important because
    /// macOS re-instantiates the preview view in System Settings on
    /// practically every interaction: without a cache, every instance
    /// would re-parse the OBJ from scratch (1-2 seconds of blocking per
    /// instance for large GLB/USDZ conversions -- observed as a sluggish
    /// preview with an 11MB spaceship OBJ). mtime is part of the key so a
    /// newly generated model under the same cache path (text changed ->
    /// different hash filename; but fallbacks/bundled models keep their
    /// path) isn't served stale.
    private static var cache: [String: TeapotMesh] = [:]
    private static let cacheLock = NSLock()
    private static let cacheLimit = 6

    static func cached(device: MTLDevice, resourceURL: URL) -> TeapotMesh? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: resourceURL.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(resourceURL.path)|\(mtime)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        // Load outside the lock (can take seconds for large models); in a
        // race, two instances load in duplicate and the second one wins
        // the cache slot -- harmless.
        guard let mesh = TeapotMesh(device: device, resourceURL: resourceURL) else { return nil }
        cacheLock.lock()
        if cache.count >= cacheLimit {
            cache.removeAll() // simple instead of LRU -- this case is rare
        }
        cache[key] = mesh
        cacheLock.unlock()
        return mesh
    }

    init?(device: MTLDevice, resourceURL: URL) {
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: resourceURL, vertexDescriptor: nil, bufferAllocator: allocator)
        guard let mdlMesh = asset.object(at: 0) as? MDLMesh else { return nil }
        mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)

        let bbox = mdlMesh.boundingBox
        let minB = bbox.minBounds
        let maxB = bbox.maxBounds
        let center = SIMD3<Float>(
            (minB.x + maxB.x) * 0.5,
            (minB.y + maxB.y) * 0.5,
            (minB.z + maxB.z) * 0.5
        )
        let extent = max(maxB.x - minB.x, max(maxB.y - minB.y, maxB.z - minB.z))
        let scale = Self.fitScale / (extent == 0 ? 1 : extent)

        // Read submeshes/materials BEFORE building the MTKMesh
        // (MDLMesh.submeshes is available independently of that): this
        // lets us decide, before GPU buffer creation, whether tangents are
        // needed for normal mapping -- addTangentBasis must run BEFORE
        // MTKMesh(mesh:device:), otherwise the tangent column is missing
        // from the finished vertex buffer.
        let mdlSubmeshes = mdlMesh.submeshes as? [MDLSubmesh] ?? []
        let kinds = mdlSubmeshes.map { SubmeshKind.classify(materialName: $0.material?.name) }
        let isPBRModel = kinds.contains(.pbr)
        let hasUVsBeforeTangents = Self.hasAttribute(mdlMesh.vertexDescriptor, named: MDLVertexAttributeTextureCoordinate)

        // Only generate tangents for imported PBR models (our own, freshly
        // written GLB/USDZ conversion with a SINGLE vertex domain) -- for
        // raw USD assets with separate attribute domains this would be
        // risky (see UsdzImport.swift), but doesn't affect us here since
        // we're reading our own OBJ. Best-effort: if generation fails, or
        // the Metal side doesn't honor the assumed attribute order, the
        // model simply stays usable without normal mapping (see the
        // hasTangentAttribute check below).
        var mdlHasTangentAttribute = false
        if isPBRModel, hasUVsBeforeTangents {
            mdlMesh.addTangentBasis(
                forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                normalAttributeNamed: MDLVertexAttributeNormal,
                tangentAttributeNamed: MDLVertexAttributeTangent
            )
            mdlHasTangentAttribute = Self.hasAttribute(mdlMesh.vertexDescriptor, named: MDLVertexAttributeTangent)
        }

        guard let mtkMesh = try? MTKMesh(mesh: mdlMesh, device: device) else { return nil }

        let mdlVertexDescriptor = mtkMesh.vertexDescriptor
        let hasTexCoords = Self.hasAttribute(mdlVertexDescriptor, named: MDLVertexAttributeTextureCoordinate)
        let metalVertexDescriptor = MTKMetalVertexDescriptorFromModelIO(mdlVertexDescriptor) ?? MTLVertexDescriptor()
        // Extra safety net: the PBR vertex shader expects the tangent at a
        // fixed attribute index (see Shaders.metal) -- normal mapping only
        // actually gets enabled when ModelIO really placed it there
        // (otherwise silently do without it instead of rendering with
        // misinterpreted vertex data).
        let tangentAttributeIndex = 3
        let metalHasTangentAttribute = metalVertexDescriptor.attributes[tangentAttributeIndex].format != .invalid

        let colors = mdlSubmeshes.map { Self.readBaseColor(material: $0.material) }
        let texture = Self.loadBaseColorTexture(device: device, submeshes: mdlSubmeshes, modelDir: resourceURL.deletingLastPathComponent())

        var ormTexture: MTLTexture?
        var emissiveTexture: MTLTexture?
        var normalTexture: MTLTexture?
        if isPBRModel {
            let mtlURL = resourceURL.deletingPathExtension().appendingPathExtension("mtl")
            let maps = Self.parsePBRTextureFileNames(mtlURL: mtlURL)
            let loader = MTKTextureLoader(device: device)
            // Same gamma-space pipeline as baseColorTexture -- ORM/normal
            // are linear data channels regardless, sRGB would be wrong here.
            let options: [MTKTextureLoader.Option: Any] = [.SRGB: false]
            let modelDir = resourceURL.deletingLastPathComponent()
            if let ormName = maps.orm {
                ormTexture = try? loader.newTexture(URL: modelDir.appendingPathComponent(ormName), options: options)
            }
            if let emissiveName = maps.emissive {
                emissiveTexture = try? loader.newTexture(URL: modelDir.appendingPathComponent(emissiveName), options: options)
            }
            if let normalName = maps.normal, mdlHasTangentAttribute, metalHasTangentAttribute {
                normalTexture = try? loader.newTexture(URL: modelDir.appendingPathComponent(normalName), options: options)
            }
        }

        self.mtkMesh = mtkMesh
        self.center = center
        self.scale = scale
        self.submeshKinds = kinds
        self.submeshColors = colors
        self.baseColorTexture = texture
        self.ormTexture = ormTexture
        self.emissiveTexture = emissiveTexture
        self.normalTexture = normalTexture
        self.hasTangentNormalMapping = normalTexture != nil
        self.vertexDescriptor = metalVertexDescriptor
        self.hasTexCoords = hasTexCoords
        self.boundsMin = (SIMD3<Float>(minB.x, minB.y, minB.z) - center) * scale
        self.boundsMax = (SIMD3<Float>(maxB.x, maxB.y, maxB.z) - center) * scale
    }

    /// Reads the (non-standard-OBJ, self-invented) PBR texture lines
    /// directly from the MTL text -- ModelIO's OBJ/MTL parser only knows
    /// standard directives (`map_Kd` etc.) and would silently ignore
    /// `map_ORM` & co., i.e. never even offer them as a material property.
    /// Since `MeshAtlas.writeObjMtl` writes exactly ONE combined "pbr"
    /// material group per model, a simple text scan without tying it to a
    /// specific material name is enough.
    private static func parsePBRTextureFileNames(mtlURL: URL) -> (orm: String?, emissive: String?, normal: String?) {
        guard let text = try? String(contentsOf: mtlURL, encoding: .utf8) else { return (nil, nil, nil) }
        var orm: String?
        var emissive: String?
        var normal: String?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("map_ORM ") {
                orm = String(line.dropFirst("map_ORM ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("map_Emissive ") {
                emissive = String(line.dropFirst("map_Emissive ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("map_Normal ") {
                normal = String(line.dropFirst("map_Normal ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return (orm, emissive, normal)
    }

    private static func hasAttribute(_ descriptor: MDLVertexDescriptor, named name: String) -> Bool {
        (descriptor.attributes as? [MDLVertexAttribute])?.contains { $0.name == name } ?? false
    }

    private static func readBaseColor(material: MDLMaterial?) -> SIMD3<Float>? {
        guard let material else { return nil }
        for semantic in [MDLMaterialSemantic.baseColor] {
            if let property = material.property(with: semantic), property.type == .float3 {
                let v = property.float3Value
                return SIMD3<Float>(v.x, v.y, v.z)
            }
        }
        return nil
    }

    /// Searches ALL submeshes (not just the first) for a base color
    /// texture -- with multiple materials, the textured one can be at any
    /// position.
    private static func loadBaseColorTexture(device: MTLDevice, submeshes: [MDLSubmesh], modelDir: URL) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        // Gamma-space pipeline (the drawable is BGRA8Unorm, no shader
        // encodes sRGB back) -- sRGB deliberately off, otherwise textures
        // look too dark.
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false]
        for submesh in submeshes {
            guard let material = submesh.material else { continue }
            guard let property = material.property(with: .baseColor) else { continue }
            if property.type == .texture, let mdlTexture = property.textureSamplerValue?.texture {
                if let texture = try? loader.newTexture(texture: mdlTexture, options: options) {
                    return texture
                }
            }
            if property.type == .string, let path = property.stringValue, !path.isEmpty {
                let url = modelDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path),
                   let texture = try? loader.newTexture(URL: url, options: options) {
                    return texture
                }
            }
        }
        return nil
    }

    /// true when more than one submesh exists -- each submesh is then
    /// colored per `submeshKinds`/`submeshColors` instead of the uniform
    /// single-material logic (texture or default green).
    var isMultiMaterial: Bool { mtkMesh.submeshes.count > 1 }

    func bindVertexBuffers(_ encoder: MTLRenderCommandEncoder) {
        for (index, vertexBuffer) in mtkMesh.vertexBuffers.enumerated() {
            encoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: index)
        }
    }

    func drawSubmesh(_ index: Int, encoder: MTLRenderCommandEncoder) {
        let submesh = mtkMesh.submeshes[index]
        encoder.drawIndexedPrimitives(
            type: submesh.primitiveType,
            indexCount: submesh.indexCount,
            indexType: submesh.indexType,
            indexBuffer: submesh.indexBuffer.buffer,
            indexBufferOffset: submesh.indexBuffer.offset
        )
    }

    /// Raw triangle positions (local model space, already centered+scaled
    /// as when rendering) for GPU raycasting -- 3 positions per triangle,
    /// all submeshes combined. Read directly from the already-loaded
    /// rendering mesh instead of being parsed separately: no second parser
    /// needed, and by construction exactly matches the rendered geometry.
    lazy var raycastTriangles: [SIMD3<Float>] = extractTriangles()

    private func extractTriangles() -> [SIMD3<Float>] {
        let posAttr = vertexDescriptor.attributes[0]!
        let bufferIndex = posAttr.bufferIndex
        let posOffset = posAttr.offset
        let stride = vertexDescriptor.layouts[bufferIndex]!.stride
        guard bufferIndex < mtkMesh.vertexBuffers.count else { return [] }
        let vb = mtkMesh.vertexBuffers[bufferIndex]
        let vertexBase = vb.buffer.contents().advanced(by: vb.offset)

        func position(at vertexIndex: Int) -> SIMD3<Float> {
            let base = vertexBase.advanced(by: posOffset + vertexIndex * stride)
            let x = base.loadUnaligned(fromByteOffset: 0, as: Float.self)
            let y = base.loadUnaligned(fromByteOffset: 4, as: Float.self)
            let z = base.loadUnaligned(fromByteOffset: 8, as: Float.self)
            return (SIMD3<Float>(x, y, z) - center) * scale
        }

        var triangles: [SIMD3<Float>] = []
        for submesh in mtkMesh.submeshes {
            let count = submesh.indexCount
            let indexBase = submesh.indexBuffer.buffer.contents().advanced(by: submesh.indexBuffer.offset)
            if submesh.indexType == .uint16 {
                let ptr = indexBase.assumingMemoryBound(to: UInt16.self)
                for i in 0..<count { triangles.append(position(at: Int(ptr[i]))) }
            } else {
                let ptr = indexBase.assumingMemoryBound(to: UInt32.self)
                for i in 0..<count { triangles.append(position(at: Int(ptr[i]))) }
            }
        }
        return triangles
    }
}
