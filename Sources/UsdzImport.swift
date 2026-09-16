import Compression
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Metal
import MetalKit
import ModelIO
import simd
import UniformTypeIdentifiers

/// Runtime converter: a user-chosen .usdz/.usd/.usda file -> OBJ+MTL.
///
/// Unlike glTF/GLB, ModelIO imports the binary USD format NATIVELY -- the
/// complex USD "Crate" binary format is therefore NOT parsed here at all,
/// it's loaded via MDLAsset. This module reads out the resulting
/// MDLMesh submeshes/materials and writes them -- like GLB -- via
/// `MeshAtlas` into a unified OBJ+MTL (including a texture atlas for
/// multi-material models) that `TeapotMesh` can load unchanged.
///
/// Flow per source mesh (see `extractMeshes`):
///   * makeVerticesUnique -- USD frequently separates attribute domains
///     (e.g. "vertex"-interpolated positions with fewer entries than
///     "faceVarying"-interpolated UVs/normals); without this call the
///     attribute buffers would have DIFFERENT lengths and a shared index
///     buffer would partly point outside the position domain.
///   * Going through an MTKMesh (no rendering, just memory layout) forces
///     ModelIO to bring ALL attributes into a consistent vertex/index
///     layout.
///
/// Limitations: only MDLMesh nodes (no cameras/lights), animated scenes
/// only at t=0. Multi-material models go through `MeshAtlas`'s PBR texture
/// atlases just like GLB -- each material keeps its real metallic/
/// roughness/emissive/normal values PER PIXEL instead of a coarse
/// chrome/non-chrome triangle split.
enum UsdzImport {
    private static let meshVersion = 14
    private static let keepCachedModels = 6
    static let maxTotalVertices = 200_000

    private static let log = MeshAtlas.makeLogger(tag: "usdz")

    // MARK: - Matrix helpers

    private static func toDouble4x4(_ m: matrix_float4x4) -> simd_double4x4 {
        simd_double4x4(columns: (
            SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1),
            SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3)
        ))
    }

    private static func nodeLocalMatrix(_ obj: MDLObject) -> simd_double4x4 {
        guard let transform = obj.transform else { return matrix_identity_double4x4 }
        return toDouble4x4(transform.localTransform?(atTime: 0) ?? transform.matrix)
    }

    private static func transformPoint(_ m: simd_double4x4, _ p: SIMD3<Double>) -> SIMD3<Double> {
        let v = m * SIMD4<Double>(p, 1)
        return SIMD3<Double>(v.x, v.y, v.z)
    }

    private static func transformDir(_ m: simd_double4x4, _ v: SIMD3<Double>) -> SIMD3<Double> {
        let r = m * SIMD4<Double>(v, 0)
        return SIMD3<Double>(r.x, r.y, r.z)
    }

    private static func normalize3(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let len = simd_length(v)
        return len < 1e-12 ? SIMD3<Double>(0, 1, 0) : v / len
    }

    // MARK: - Vertex/index buffer access (unified via MTKMesh)

    private static func attributeArray(_ mtkMesh: MTKMesh, attributeName: String, nComponents: Int) -> [[Double]]? {
        let vd = mtkMesh.vertexDescriptor
        var bufIdx: Int?
        var offset = 0
        for case let attr as MDLVertexAttribute in vd.attributes {
            if attr.name == attributeName {
                bufIdx = attr.bufferIndex
                offset = attr.offset
                break
            }
        }
        guard let bufIdx else { return nil }
        guard let layout = vd.layouts[bufIdx] as? MDLVertexBufferLayout else { return nil }
        let stride = layout.stride
        guard bufIdx < mtkMesh.vertexBuffers.count else { return nil }
        let vb = mtkMesh.vertexBuffers[bufIdx]
        let count = mtkMesh.vertexCount
        let base = vb.buffer.contents() + vb.offset
        var out: [[Double]] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let ptr = (base + i * stride + offset).assumingMemoryBound(to: Float32.self)
            var comps = [Double](repeating: 0, count: nComponents)
            for c in 0..<nComponents {
                comps[c] = Double(ptr[c])
            }
            out.append(comps)
        }
        return out
    }

    private static func submeshIndices(_ submesh: MTKSubmesh) -> [Int] {
        let ib = submesh.indexBuffer
        let count = submesh.indexCount
        let base = ib.buffer.contents() + ib.offset
        switch submesh.indexType {
        case .uint16:
            let ptr = base.assumingMemoryBound(to: UInt16.self)
            return (0..<count).map { Int(ptr[$0]) }
        case .uint32:
            let ptr = base.assumingMemoryBound(to: UInt32.self)
            return (0..<count).map { Int(ptr[$0]) }
        @unknown default:
            return []
        }
    }

    // MARK: - Material

    private static func materialFloat3(_ material: MDLMaterial?, _ names: [String]) -> SIMD3<Double>? {
        guard let material else { return nil }
        for name in names {
            guard let prop = material.propertyNamed(name) else { continue }
            if prop.type == .float3 || prop.type == .float4 || prop.type == .color {
                let v = prop.float3Value
                return SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
            }
        }
        return nil
    }

    private static func materialFloat(_ material: MDLMaterial?, _ names: [String]) -> Double? {
        guard let material else { return nil }
        for name in names {
            guard let prop = material.propertyNamed(name) else { continue }
            if prop.type == .float {
                return Double(prop.floatValue)
            }
        }
        return nil
    }

    private static func encodeMDLTextureToPNG(_ mdlTexture: MDLTexture) -> Data? {
        // takeUnretainedValue, NOT takeRetainedValue: imageFromTexture()
        // returns an autoreleased CGImage. An extra release caused a crash
        // when the autorelease pool drained at the end of the frame
        // (objc_autoreleasePoolPop).
        guard let cgImage = mdlTexture.imageFromTexture()?.takeUnretainedValue() else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }

    /// Reads the image data of a stringValue reference delivered by an
    /// MDLMaterialProperty.
    ///
    /// ModelIO does NOT reference textures embedded in a USDZ as a normal
    /// filesystem path, but via the special syntax
    /// "<usdz-file>[<internal-zip-path>]" (e.g.
    /// "spaceship.usdz[0/Material_baseColor.jpg]") -- USDZ is (usually
    /// uncompressed) a ZIP archive, and the texture must be read directly
    /// out of it.
    private static func resolveTextureURI(_ uri: String, sourceDir: URL) -> (Data?, String?) {
        guard !uri.isEmpty else { return (nil, nil) }
        if uri.hasSuffix("]"), let bracket = uri.lastIndex(of: "[") {
            let archivePath = String(uri[..<bracket]).trimmingCharacters(in: .whitespaces)
            let inner = String(uri[uri.index(after: bracket)..<uri.index(before: uri.endIndex)])
            if !archivePath.isEmpty && !inner.isEmpty,
               let data = ZipReader.readEntry(archivePath: archivePath, entryName: inner) {
                let ext = (inner as NSString).pathExtension.lowercased()
                return (data, ext.isEmpty ? ".png" : ".\(ext)")
            }
            return (nil, nil)
        }
        var candidate = URL(fileURLWithPath: uri)
        if !uri.hasPrefix("/") {
            candidate = sourceDir.appendingPathComponent(uri)
        }
        if let data = try? Data(contentsOf: candidate) {
            let ext = candidate.pathExtension.lowercased()
            return (data, ext.isEmpty ? ".png" : ".\(ext)")
        }
        return (nil, nil)
    }

    /// Image data of the first texture reference among the given properties.
    private static func materialTextureBytes(_ material: MDLMaterial?, _ propNames: [String], sourceDir: URL) -> (Data?, String?) {
        guard let material else { return (nil, nil) }
        for name in propNames {
            guard let prop = material.propertyNamed(name) else { continue }
            if let sampler = prop.textureSamplerValue, let mdlTexture = sampler.texture {
                if let bytes = encodeMDLTextureToPNG(mdlTexture) {
                    return (bytes, ".png")
                }
            }
            if let uri = prop.stringValue {
                let (bytes, ext) = resolveTextureURI(uri, sourceDir: sourceDir)
                if bytes != nil { return (bytes, ext) }
            }
            if let url = prop.urlValue {
                let (bytes, ext) = resolveTextureURI(url.path, sourceDir: sourceDir)
                if bytes != nil { return (bytes, ext) }
            }
        }
        return (nil, nil)
    }

    /// All material data needed for real pixel PBR shading (instead of
    /// pre-classifying into "chrome"/"top"/"outer" -- the shader now makes
    /// that decision PER PIXEL from the real metallic/roughness values,
    /// no longer a coarse triangle split).
    private struct MaterialInfo {
        var texBytes: Data?
        var texExt: String?
        var flatRGB: SIMD3<Double>
        var metallicFactor: Double
        var roughnessFactor: Double
        /// USD exports Metalness/Roughness/Occlusion as separate grayscale
        /// images (every channel identical) instead of one packed glTF
        /// image.
        var metallicTexBytes: Data?
        var roughnessTexBytes: Data?
        var occlusionTexBytes: Data?
        var emissiveFactor: SIMD3<Double>
        var emissiveTexBytes: Data?
        var normalTexBytes: Data?
    }

    private static func materialInfo(_ material: MDLMaterial?, sourceDir: URL) -> MaterialInfo {
        // "diffuseColor" first: for USD/UsdPreviewSurface materials (not
        // just our own exports -- Apple's own USDZ sample files too),
        // ModelIO always additionally provides a "baseColor" property that
        // is just a placeholder with the generic 18%-gray default
        // (0.18, 0.18, 0.18), regardless of what's actually set in the USD
        // -- querying it first would let that placeholder mask any real
        // color, making the model appear completely gray. "baseColor"
        // remains a fallback for the case where a material really only has
        // this (e.g. glTF-derived) property.
        let baseColor = materialFloat3(material, ["diffuseColor", "baseColor"]) ?? SIMD3<Double>(0.8, 0.8, 0.8)

        let (texBytes, texExt) = materialTextureBytes(material, ["diffuseColor", "baseColor"], sourceDir: sourceDir)
        let (metalTex, _) = materialTextureBytes(material, ["metallic"], sourceDir: sourceDir)
        let (roughTex, _) = materialTextureBytes(material, ["roughness"], sourceDir: sourceDir)

        // IMPORTANT: when "metallic"/"roughness" is connected to a texture
        // (no scalar value of its own in the USD), ModelIO's propertyNamed()
        // returns a type-mismatch fallback (empirically 0.0 for metallic,
        // 0.5 for roughness) instead of nil -- materialFloat() should have
        // treated that as "no scalar present", but instead gets a seemingly
        // valid value and wrongly adopts it as the factor. Since this factor
        // MULTIPLIES the raw texture value, a texture-driven roughness gets
        // wrongly halved(!) everywhere (0.5 instead of the correct 1.0 =
        // "take the texture unchanged") -- an otherwise near-matte photo-PBR
        // material (e.g. Mars/Earth) ends up looking noticeably glossier
        // than intended. Only without ANY texture does the USD/MaterialX
        // PreviewSurface default apply (non-metallic, medium roughness --
        // unlike glTF's metallic=1 default).
        var metallic = materialFloat(material, ["metallic"]) ?? (metalTex != nil ? 1.0 : 0.0)
        let roughness = materialFloat(material, ["roughness"]) ?? (roughTex != nil ? 1.0 : 0.5)
        let (occTex, _) = materialTextureBytes(material, ["ambientOcclusion", "occlusion"], sourceDir: sourceDir)
        let (normTex, _) = materialTextureBytes(material, ["tangentSpaceNormal", "normal"], sourceDir: sourceDir)
        // ModelIO's actual property name for MDLMaterialSemantic .emission
        // is "emissiveColor" (per the USD PreviewSurface convention), NOT
        // "emission" -- verified empirically with a custom diagnostic
        // property listing on spaceship.usdz (the entire emissive texture
        // was missing as a result, visible as completely gray engine
        // outlets instead of glowing orange ones).
        let (emisTex, _) = materialTextureBytes(material, ["emissiveColor", "emission"], sourceDir: sourceDir)
        let emissiveFactor = materialFloat3(material, ["emissiveColor", "emission"]) ?? SIMD3<Double>(0, 0, 0)

        // See MeshAtlas.channelHasRealContrast / the same fix in
        // GlbMesh.swift: a metallic texture without a real spatial
        // metal split otherwise turns matte rock falsely into glossy metal
        // when combined with a high metallicFactor.
        if let metalTex, metallic > 0, !MeshAtlas.channelHasRealContrast(metalTex, channel: 0) {
            metallic = 0
        }

        return MaterialInfo(
            texBytes: texBytes, texExt: texExt, flatRGB: baseColor,
            metallicFactor: metallic, roughnessFactor: roughness,
            metallicTexBytes: metalTex, roughnessTexBytes: roughTex, occlusionTexBytes: occTex,
            emissiveFactor: emisTex != nil ? SIMD3<Double>(1, 1, 1) : emissiveFactor,
            emissiveTexBytes: emisTex, normalTexBytes: normTex
        )
    }

    // MARK: - Scene traversal

    private static func attributeEntryCount(_ mesh: MDLMesh, _ attributeName: String) -> Int? {
        guard let vad = mesh.vertexAttributeData(forAttributeNamed: attributeName) else { return nil }
        let stride = vad.stride > 0 ? vad.stride : 1
        return vad.bufferSize / stride
    }

    /// True when normals are missing or attribute domains have different
    /// lengths. Only then does `addNormals` need to unify the domains -- on
    /// meshes that are ALREADY consistent, the same call destroys the
    /// buffers (observed empirically on a single-quad mesh: 4 positions/4
    /// normals/4 UVs -> afterwards 6 vertices with only 2 unique positions
    /// left and zero normals).
    private static func needsDomainUnification(_ mesh: MDLMesh) -> Bool {
        guard let posCount = attributeEntryCount(mesh, MDLVertexAttributePosition) else { return false }
        guard let nrmCount = attributeEntryCount(mesh, MDLVertexAttributeNormal) else { return true }
        let uvCount = attributeEntryCount(mesh, MDLVertexAttributeTextureCoordinate)
        if nrmCount != posCount { return true }
        if let uvCount, uvCount != posCount { return true }
        return false
    }

    private static func extractMeshes(_ asset: MDLAsset, device: MTLDevice, sourceDir: URL) -> [MeshAtlas.MeshPrimitive] {
        var primitives: [MeshAtlas.MeshPrimitive] = []
        var totalVertices = 0
        var statMeshes = 0
        var statSubmeshes = 0
        var statTextured = 0

        func visit(_ obj: MDLObject, _ parentMatrix: simd_double4x4) {
            guard totalVertices < maxTotalVertices else { return }
            let world = parentMatrix * nodeLocalMatrix(obj)

            if let mesh = obj as? MDLMesh {
                statMeshes += 1
                processMesh(mesh, world: world)
            }

            for child in obj.children.objects {
                visit(child, world)
            }
        }

        func processMesh(_ mesh: MDLMesh, world: simd_double4x4) {
            let needsUnification = needsDomainUnification(mesh)
            do {
                try mesh.makeVerticesUniqueAndReturnError()
            } catch {
                log("makeVerticesUnique failed for '\(mesh.name)': \(error)")
            }
            // Only call this when actually needed (see
            // needsDomainUnification): for separate domains the call
            // triggers unification; for consistent meshes it instead
            // destroys the buffers. The bounds check below catches rare
            // internal unification failures (skip the submesh instead of
            // crashing).
            if needsUnification {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
            let mtkMesh: MTKMesh
            do {
                mtkMesh = try MTKMesh(mesh: mesh, device: device)
            } catch {
                log("MTKMesh error for '\(mesh.name)': \(error)")
                return
            }
            guard let positionsRaw = attributeArray(mtkMesh, attributeName: MDLVertexAttributePosition, nComponents: 3) else { return }
            let normalsRaw = attributeArray(mtkMesh, attributeName: MDLVertexAttributeNormal, nComponents: 3)
            let uvsRaw = attributeArray(mtkMesh, attributeName: MDLVertexAttributeTextureCoordinate, nComponents: 2)

            let positionsWorld = positionsRaw.map { transformPoint(world, SIMD3<Double>($0[0], $0[1], $0[2])) }
            let normalsWorld: [SIMD3<Double>]
            if let normalsRaw {
                normalsWorld = normalsRaw.map { normalize3(transformDir(world, SIMD3<Double>($0[0], $0[1], $0[2]))) }
            } else {
                normalsWorld = [SIMD3<Double>](repeating: SIMD3<Double>(0, 1, 0), count: positionsWorld.count)
            }
            // USD "st" uses (like OBJ) the origin at the BOTTOM-left, and
            // ModelIO passes the values through unchanged; but the shared
            // writer pipeline (MeshAtlas.writeObjMtl) expects its input in
            // glTF convention (origin at the TOP-left). Without this
            // conversion, every USDZ texture was flipped vertically.
            let uvs: [SIMD2<Double>]? = uvsRaw.map { arr in
                arr.map { SIMD2<Double>($0[0], 1.0 - $0[1]) }
            }

            let mdlSubs = mesh.submeshes as? [MDLSubmesh]
            for (i, sub) in mtkMesh.submeshes.enumerated() {
                if totalVertices >= maxTotalVertices { break }
                statSubmeshes += 1
                var indices = submeshIndices(sub)
                if indices.isEmpty { continue }
                if let maxIdx = indices.max(), maxIdx >= positionsWorld.count {
                    // Safety net: should the unification ever return
                    // inconsistent lengths for an untested attribute
                    // combination, skip the submesh instead of crashing on
                    // a broken index.
                    log("Submesh \(i) of '\(mesh.name)' skipped: index \(maxIdx) >= \(positionsWorld.count) positions")
                    continue
                }
                let material = (mdlSubs != nil && i < mdlSubs!.count) ? mdlSubs![i].material : nil
                let info = materialInfo(material, sourceDir: sourceDir)
                if info.texBytes != nil { statTextured += 1 }
                // Key by object identity rather than just the name:
                // different materials may share a name (often "Material"
                // from converters) -- a pure name key would wrongly assign
                // them the same atlas cell.
                let materialKey: String
                if let material {
                    materialKey = "\(material.name)#\(ObjectIdentifier(material).hashValue)"
                } else {
                    materialKey = "mesh\(ObjectIdentifier(mesh).hashValue)_\(i)"
                }

                // A texture-less, NON-METALLIC material doesn't need PBR
                // atlas treatment -- it instead renders with the same
                // simple shader as the bundled models (mesh_col_fs), so a
                // flat color looks the same as the same Kd in a hand-
                // written .mtl, instead of appearing washed out by the PBR
                // ambient light. Texture-less METALLIC materials
                // deliberately stay on "pbr": the dedicated "chrome" shader
                // (mesh_chrome_fs) ignores roughnessFactor entirely and
                // always looks mirror-smooth -- for rougher metals (e.g.
                // copper heat pipes without their own texture) the
                // roughness-aware PBR path is closer to the original.
                let hasAnyTexture = info.texBytes != nil || info.metallicTexBytes != nil
                    || info.roughnessTexBytes != nil || info.occlusionTexBytes != nil
                    || info.emissiveTexBytes != nil || info.normalTexBytes != nil
                let kind = (!hasAnyTexture && info.metallicFactor <= 0.5) ? "outer" : "pbr"

                let primitive = MeshAtlas.MeshPrimitive(
                    positions: positionsWorld, normals: normalsWorld, uvs: uvs,
                    indices: indices, kind: kind,
                    texBytes: info.texBytes, texExt: info.texExt,
                    flatRGB: info.flatRGB, materialKey: materialKey
                )
                primitive.metallicFactor = info.metallicFactor
                primitive.roughnessFactor = info.roughnessFactor
                primitive.metallicTexBytes = info.metallicTexBytes
                primitive.roughnessTexBytes = info.roughnessTexBytes
                primitive.occlusionTexBytes = info.occlusionTexBytes
                primitive.emissiveFactor = info.emissiveFactor
                primitive.emissiveTexBytes = info.emissiveTexBytes
                primitive.normalTexBytes = info.normalTexBytes
                primitives.append(primitive)
                totalVertices += positionsWorld.count
            }
        }

        for i in 0..<asset.count {
            visit(asset.object(at: i), matrix_identity_double4x4)
        }
        log("Meshes extracted: \(statMeshes) (submeshes: \(statSubmeshes)), materials with texture: \(statTextured), total vertices: \(totalVertices)")
        return primitives
    }

    // MARK: - Entry point

    private static func cacheDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Matrix3DSaverX/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Converts the chosen .usdz/.usd/.usda file into a cached OBJ+MTL. nil
    /// on any failure -- the caller then falls back to the default model.
    static func ensureUsdzModel(sourcePath: String, bookmark: Data?) -> URL? {
        let scopedURL = MeshAtlas.startSecurityScopedAccess(bookmark: bookmark, log: log)
        defer { MeshAtlas.stopSecurityScopedAccess(scopedURL) }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            log("Source file not accessible: \(sourcePath)")
            return nil
        }
        return convertUsdz(sourceURL)
    }

    private static func convertUsdz(_ sourceURL: URL) -> URL? {
        guard let stat = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let size = stat[.size] as? Int,
              let mtime = stat[.modificationDate] as? Date else { return nil }
        let mtimeNs = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
        let keySource = "v\(meshVersion)|\(sourceURL.resolvingSymlinksInPath().path)|\(mtimeNs)|\(size)"
        let digest = Insecure.SHA1.hash(data: Data(keySource.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        let cache = cacheDir()
        let objPath = cache.appendingPathComponent("usdz_\(key).obj")
        let mtlPath = cache.appendingPathComponent("usdz_\(key).mtl")
        let fm = FileManager.default
        if fm.fileExists(atPath: objPath.path) && fm.fileExists(atPath: mtlPath.path) {
            return objPath
        }

        log("converting \(sourceURL.lastPathComponent) (\(size) bytes)")
        guard let device = MetalDevicePicker.preferred(log: log) else {
            log("no Metal device available")
            return nil
        }
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: sourceURL, vertexDescriptor: nil, bufferAllocator: allocator)
        guard asset.count > 0 else {
            log("MDLAsset empty or not loadable")
            return nil
        }
        // Let ModelIO resolve textures directly where it can -- the
        // stringValue zip syntax remains a fallback (resolveTextureURI).
        asset.loadTextures()

        let primitives = extractMeshes(asset, device: device, sourceDir: sourceURL.deletingLastPathComponent())
        guard !primitives.isEmpty else {
            log("no triangle primitives found -> fallback")
            return nil
        }

        var textureName: String?
        var pbrTextures: MeshAtlas.PBRTextureNames?
        var atlasRects: [String: (Double, Double, Double, Double)] = [:]
        if let atlases = MeshAtlas.buildPBRAtlases(primitives, log: log) {
            let baseColorName = "usdz_\(key)_basecolor.png"
            let ormName = "usdz_\(key)_orm.png"
            try? atlases.baseColorPNG.write(to: cache.appendingPathComponent(baseColorName))
            try? atlases.ormPNG.write(to: cache.appendingPathComponent(ormName))
            var emissiveName: String?
            if let emissivePNG = atlases.emissivePNG {
                emissiveName = "usdz_\(key)_emissive.png"
                try? emissivePNG.write(to: cache.appendingPathComponent(emissiveName!))
            }
            var normalName: String?
            if let normalPNG = atlases.normalPNG {
                normalName = "usdz_\(key)_normal.png"
                try? normalPNG.write(to: cache.appendingPathComponent(normalName!))
            }
            pbrTextures = MeshAtlas.PBRTextureNames(baseColor: baseColorName, orm: ormName, emissive: emissiveName, normal: normalName)
            atlasRects = atlases.rects
        } else {
            // Fallback: the old single-texture/flat-color logic (no PBR
            // shading) -- only shows ONE material correctly. In practice
            // only kicks in if CoreGraphics itself were unavailable.
            let (texBytes, texExt) = MeshAtlas.pickTexture(primitives)
            if let texBytes {
                textureName = "usdz_\(key)_texture\(texExt ?? ".png")"
                try? texBytes.write(to: cache.appendingPathComponent(textureName!))
                log("using texture from USD material (\(texBytes.count) bytes, \(texExt ?? "?"))")
            } else if let flat = MeshAtlas.pickFlatColor(primitives) {
                textureName = "usdz_\(key)_texture.png"
                MeshAtlas.writeSolidPNG(to: cache.appendingPathComponent(textureName!), rgb: flat)
                log("no texture found -> synthetic flat color \(flat)")
            } else {
                log("no texture and no uniform flat color -> default color (outer)")
            }
        }

        do {
            try MeshAtlas.writeObjMtl(
                primitives, objPath: objPath, mtlPath: mtlPath,
                textureName: textureName, pbrTextures: pbrTextures, atlasRects: atlasRects,
                prefix: "usdz", sourceLabel: "USD"
            )
        } catch {
            log("EXC writeObjMtl: \(error)")
            return nil
        }
        MeshAtlas.pruneCache(cacheDir: cache, objPrefix: "usdz_", keep: keepCachedModels)
        return objPath
    }
}

/// Minimal ZIP reader for textures embedded in a USDZ (macOS has no public
/// ZIP API). USDZ is, per spec, a (usually uncompressed/"stored") ZIP
/// archive; Deflate is nonetheless supported via the Compression framework.
enum ZipReader {
    static func readEntry(archivePath: String, entryName: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: archivePath)) else { return nil }
        // Search for the End-of-Central-Directory (signature 0x06054b50)
        // from the end (up to a 64KB comment allowed).
        let minEOCD = 22
        guard data.count >= minEOCD else { return nil }
        var eocdOffset = -1
        let searchStart = max(0, data.count - 65_557)
        var i = data.count - minEOCD
        while i >= searchStart {
            if u32(data, i) == 0x0605_4b50 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { return nil }
        let cdOffset = Int(u32(data, eocdOffset + 16))
        let cdCount = Int(u16(data, eocdOffset + 10))

        var offset = cdOffset
        for _ in 0..<cdCount {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4b50 else { return nil }
            let method = Int(u16(data, offset + 10))
            let compSize = Int(u32(data, offset + 20))
            let nameLen = Int(u16(data, offset + 28))
            let extraLen = Int(u16(data, offset + 30))
            let commentLen = Int(u16(data, offset + 32))
            let localOffset = Int(u32(data, offset + 42))
            guard offset + 46 + nameLen <= data.count else { return nil }
            let name = String(data: data.subdata(in: (offset + 46)..<(offset + 46 + nameLen)), encoding: .utf8) ?? ""
            if name == entryName {
                // Local header: name/extra lengths can differ there.
                guard localOffset + 30 <= data.count, u32(data, localOffset) == 0x0403_4b50 else { return nil }
                let lNameLen = Int(u16(data, localOffset + 26))
                let lExtraLen = Int(u16(data, localOffset + 28))
                let dataStart = localOffset + 30 + lNameLen + lExtraLen
                guard dataStart + compSize <= data.count else { return nil }
                let payload = data.subdata(in: dataStart..<(dataStart + compSize))
                switch method {
                case 0:
                    return payload
                case 8:
                    return inflate(payload)
                default:
                    return nil
                }
            }
            offset += 46 + nameLen + extraLen + commentLen
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in (0..<4).reversed() {
            v = (v << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return v
    }

    /// Raw DEFLATE (ZIP method 8) -- COMPRESSION_ZLIB in the Compression
    /// framework is exactly the raw DEFLATE stream without a zlib header.
    private static func inflate(_ compressed: Data) -> Data? {
        // Grow the output buffer iteratively (the ZIP central directory
        // does know the original size, but stay defensive).
        var capacity = max(compressed.count * 4, 64 * 1024)
        for _ in 0..<6 {
            let result = compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
                guard let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
                let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                defer { dst.deallocate() }
                let written = compression_decode_buffer(dst, capacity, srcPtr, compressed.count, nil, COMPRESSION_ZLIB)
                guard written > 0 else { return nil }
                // Buffer full -> likely truncated, try a bigger one.
                if written == capacity { return Data() }
                return Data(bytes: dst, count: written)
            }
            if let result {
                if result.isEmpty {
                    capacity *= 4
                    continue
                }
                return result
            }
            return nil
        }
        return nil
    }
}
