import CryptoKit
import Foundation
import simd

/// Runtime converter: a user-chosen .glb file -> OBJ+MTL.
///
/// glTF/GLB is the most widespread free 3D exchange format (Sketchfab,
/// Poly Pizza, ...), but ModelIO on macOS does NOT import it natively
/// (unlike OBJ/USD/USDZ/STL/PLY). Instead of a third-party library, this
/// module parses the binary GLB container directly (Foundation:
/// Data/JSONSerialization) and writes, via `MeshAtlas`, an OBJ+MTL that the
/// existing ModelIO/MTKMesh pipeline (`TeapotMesh`) can load unchanged:
/// centering/scaling, material recognition via name substring, GPU
/// raycasting, physics -- all included.
///
/// Limitations (deliberate simplifications, not a full-fledged importer):
///   * Only triangle primitives (mode 4 / default).
///   * Sparse accessors are not supported (rare).
///   * Normal transformation uses the linear part of the node matrix
///     (correct for rotation + uniform scaling).
///   * Multi-material models go through `MeshAtlas`'s PBR texture atlases
///     (the renderer only supports ONE global texture set); each material
///     keeps its real metallic/roughness/emissive/normal values PER PIXEL
///     -- no more coarse chrome/non-chrome triangle split (which, for
///     example, wrongly classified whole textured parts as uniform chrome,
///     see the comment in MeshAtlas.swift).
enum GlbMesh {
    private static let meshVersion = 15
    private static let keepCachedModels = 6
    /// Safety net against runaway downloads.
    static let maxTotalVertices = 200_000

    private static let log = MeshAtlas.makeLogger(tag: "glb")

    // componentType -> (byte size, signed, float)
    private static let componentTypes: [Int: (size: Int, signed: Bool, isFloat: Bool)] = [
        5120: (1, true, false),   // BYTE
        5121: (1, false, false),  // UNSIGNED_BYTE
        5122: (2, true, false),   // SHORT
        5123: (2, false, false),  // UNSIGNED_SHORT
        5125: (4, false, false),  // UNSIGNED_INT
        5126: (4, false, true),   // FLOAT
    ]
    private static let typeCounts: [String: Int] = [
        "SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16,
    ]

    // MARK: - GLB container / glTF JSON

    private static func readGlb(_ data: Data) throws -> (gltf: [String: Any], bin: Data?) {
        struct ParseError: Error {}
        guard data.count >= 12, data.prefix(4) == Data("glTF".utf8) else {
            log("not a valid GLB header")
            throw ParseError()
        }
        var offset = 12
        var jsonChunk: [String: Any]?
        var binChunk: Data?
        while offset + 8 <= data.count {
            let chunkLen = Int(readUInt32(data, offset))
            let chunkType = data.subdata(in: (offset + 4)..<(offset + 8))
            offset += 8
            let end = min(offset + chunkLen, data.count)
            let chunkData = data.subdata(in: offset..<end)
            offset += chunkLen
            if chunkType == Data("JSON".utf8) {
                jsonChunk = (try? JSONSerialization.jsonObject(with: chunkData)) as? [String: Any]
            } else if chunkType == Data([0x42, 0x49, 0x4E, 0x00]) { // "BIN\0"
                binChunk = chunkData
            }
        }
        guard let gltf = jsonChunk else {
            log("no JSON chunk found in the GLB")
            throw ParseError()
        }
        return (gltf, binChunk)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<(offset + 4)) }
        return UInt32(littleEndian: v)
    }

    private static func loadBuffers(_ gltf: [String: Any], bin: Data?, sourceDir: URL) -> [Data]? {
        var buffers: [Data] = []
        for (i, bufAny) in ((gltf["buffers"] as? [[String: Any]]) ?? []).enumerated() {
            if let uri = bufAny["uri"] as? String {
                if uri.hasPrefix("data:") {
                    guard let comma = uri.firstIndex(of: ","),
                          let payload = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                        log("buffer \(i): data: URI not decodable")
                        return nil
                    }
                    buffers.append(payload)
                } else {
                    let path = sourceDir.appendingPathComponent(uri.removingPercentEncoding ?? uri)
                    guard let data = try? Data(contentsOf: path) else {
                        log("external buffer file not found: \(uri)")
                        return nil
                    }
                    buffers.append(data)
                }
            } else {
                guard let bin else {
                    log("buffer \(i) has no uri, but there's no BIN chunk either")
                    return nil
                }
                buffers.append(bin)
            }
        }
        return buffers
    }

    /// Reads an accessor as [[Double]] (each entry `n_comp` values).
    private static func readAccessor(_ gltf: [String: Any], _ buffers: [Data], _ accessorIndex: Int) -> [[Double]]? {
        guard let accessors = gltf["accessors"] as? [[String: Any]],
              accessorIndex >= 0, accessorIndex < accessors.count else { return nil }
        let acc = accessors[accessorIndex]
        guard let count = acc["count"] as? Int,
              let typeName = acc["type"] as? String,
              let nComp = typeCounts[typeName],
              let compTypeRaw = acc["componentType"] as? Int,
              let compType = componentTypes[compTypeRaw] else { return nil }

        guard let bvIndex = acc["bufferView"] as? Int else {
            // Sparse-only/zero-valued accessors: not supported (rare)
            // -> neutral zeros instead of crashing.
            return Array(repeating: [Double](repeating: 0, count: nComp), count: count)
        }
        guard let bufferViews = gltf["bufferViews"] as? [[String: Any]],
              bvIndex < bufferViews.count else { return nil }
        let bv = bufferViews[bvIndex]
        guard let bufIndex = bv["buffer"] as? Int, bufIndex < buffers.count else { return nil }
        let buf = buffers[bufIndex]
        let byteOffset = ((bv["byteOffset"] as? Int) ?? 0) + ((acc["byteOffset"] as? Int) ?? 0)
        let stride = (bv["byteStride"] as? Int) ?? (compType.size * nComp)

        var values: [[Double]] = []
        values.reserveCapacity(count)
        let ok: Bool = buf.withUnsafeBytes { raw -> Bool in
            for i in 0..<count {
                let base = byteOffset + i * stride
                guard base + compType.size * nComp <= raw.count else { return false }
                var comps = [Double](repeating: 0, count: nComp)
                for c in 0..<nComp {
                    let off = base + c * compType.size
                    if compType.isFloat {
                        comps[c] = Double(raw.loadUnaligned(fromByteOffset: off, as: Float32.self))
                    } else {
                        switch (compType.size, compType.signed) {
                        case (1, true): comps[c] = Double(raw.loadUnaligned(fromByteOffset: off, as: Int8.self))
                        case (1, false): comps[c] = Double(raw.loadUnaligned(fromByteOffset: off, as: UInt8.self))
                        case (2, true): comps[c] = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: Int16.self)))
                        case (2, false): comps[c] = Double(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self)))
                        default: comps[c] = Double(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
                        }
                    }
                }
                values.append(comps)
            }
            return true
        }
        return ok ? values : nil
    }

    // MARK: - Node matrices (column-major like glTF; simd is column-major too)

    private static func nodeLocalMatrix(_ node: [String: Any]) -> simd_double4x4 {
        if let m = node["matrix"] as? [Any], m.count == 16 {
            let v = m.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            return simd_double4x4(columns: (
                SIMD4<Double>(v[0], v[1], v[2], v[3]),
                SIMD4<Double>(v[4], v[5], v[6], v[7]),
                SIMD4<Double>(v[8], v[9], v[10], v[11]),
                SIMD4<Double>(v[12], v[13], v[14], v[15])
            ))
        }
        func vec(_ key: String, _ def: [Double]) -> [Double] {
            guard let arr = node[key] as? [Any], arr.count == def.count else { return def }
            return arr.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        }
        let t = vec("translation", [0, 0, 0])
        let r = vec("rotation", [0, 0, 0, 1])
        let s = vec("scale", [1, 1, 1])
        let rot = simd_double4x4(simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
        var m = rot
        m.columns.0 *= s[0]
        m.columns.1 *= s[1]
        m.columns.2 *= s[2]
        m.columns.3 = SIMD4<Double>(t[0], t[1], t[2], 1)
        return m
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
        return len < 1e-12 ? SIMD3<Double>(0, 0, 1) : v / len
    }

    // MARK: - Image/material access

    /// Image data + file extension from a glTF 'images[]' entry.
    ///
    /// Covers all three allowed cases: embedded via bufferView (the
    /// standard case for a real GLB), via a data: URI, OR via an external
    /// relative file URI (some exporters produce ".glb" files that
    /// reference images as a loose file alongside -- without this third
    /// case, exactly that texture would stay empty).
    private static func loadImageBytes(_ gltf: [String: Any], _ buffers: [Data], image: [String: Any], sourceDir: URL) -> (Data?, String?) {
        let mime = (image["mimeType"] as? String) ?? ""
        var ext = mime.contains("jpeg") ? ".jpg" : ".png"
        if let bvIndex = image["bufferView"] as? Int,
           let bufferViews = gltf["bufferViews"] as? [[String: Any]], bvIndex < bufferViews.count {
            let bv = bufferViews[bvIndex]
            guard let bufIndex = bv["buffer"] as? Int, bufIndex < buffers.count,
                  let byteLength = bv["byteLength"] as? Int else { return (nil, nil) }
            let buf = buffers[bufIndex]
            let start = (bv["byteOffset"] as? Int) ?? 0
            let end = min(start + byteLength, buf.count)
            guard start < end else { return (nil, nil) }
            return (buf.subdata(in: start..<end), ext)
        }
        guard let uri = image["uri"] as? String, !uri.isEmpty else { return (nil, nil) }
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else { return (nil, nil) }
            let header = String(uri[..<comma])
            if header.contains("jpeg") { ext = ".jpg" }
            let payload = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            return (payload, payload != nil ? ext : nil)
        }
        let path = sourceDir.appendingPathComponent(uri.removingPercentEncoding ?? uri)
        if let data = try? Data(contentsOf: path) {
            let suffix = path.pathExtension.lowercased()
            if suffix == "jpg" || suffix == "jpeg" { ext = ".jpg" }
            else if suffix == "png" { ext = ".png" }
            return (data, ext)
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
        var texcoordSet: Int
        var metallicFactor: Double
        var roughnessFactor: Double
        /// glTF convention: G=Roughness, B=Metallic (possibly R=Occlusion,
        /// if it's the same texture index as occlusionTexture -- a common
        /// exporter optimization).
        var metallicRoughnessTexBytes: Data?
        var occlusionTexBytes: Data?
        var emissiveFactor: SIMD3<Double>
        var emissiveTexBytes: Data?
        var normalTexBytes: Data?
    }

    private static func textureBytes(_ gltf: [String: Any], _ buffers: [Data], texInfo: [String: Any]?, sourceDir: URL) -> (Data?, String?, Int) {
        guard let texInfo,
              let texIndex = texInfo["index"] as? Int,
              let textures = gltf["textures"] as? [[String: Any]], texIndex < textures.count,
              let sourceIndex = textures[texIndex]["source"] as? Int,
              let images = gltf["images"] as? [[String: Any]], sourceIndex < images.count else {
            return (nil, nil, 0)
        }
        let texcoordSet = (texInfo["texCoord"] as? Int) ?? 0
        let (bytes, ext) = loadImageBytes(gltf, buffers, image: images[sourceIndex], sourceDir: sourceDir)
        return (bytes, ext, texcoordSet)
    }

    private static func materialInfo(_ gltf: [String: Any], _ buffers: [Data], materialIndex: Int?, sourceDir: URL) -> MaterialInfo {
        guard let materialIndex,
              let materials = gltf["materials"] as? [[String: Any]],
              materialIndex < materials.count else {
            return MaterialInfo(
                texBytes: nil, texExt: nil, flatRGB: SIMD3<Double>(0.8, 0.8, 0.8), texcoordSet: 0,
                metallicFactor: 0, roughnessFactor: 1, metallicRoughnessTexBytes: nil,
                occlusionTexBytes: nil, emissiveFactor: SIMD3<Double>(0, 0, 0),
                emissiveTexBytes: nil, normalTexBytes: nil
            )
        }
        let mat = materials[materialIndex]
        let pbr = (mat["pbrMetallicRoughness"] as? [String: Any]) ?? [:]
        func rgb(_ any: Any?) -> SIMD3<Double>? {
            guard let arr = any as? [Any], arr.count >= 3 else { return nil }
            let v = arr.prefix(3).map { ($0 as? NSNumber)?.doubleValue ?? 1 }
            return SIMD3<Double>(v[0], v[1], v[2])
        }
        var baseColor = rgb(pbr["baseColorFactor"]) ?? SIMD3<Double>(1, 1, 1)
        var metallic = (pbr["metallicFactor"] as? NSNumber)?.doubleValue ?? 1.0
        let roughness = (pbr["roughnessFactor"] as? NSNumber)?.doubleValue ?? 1.0

        var baseTex = pbr["baseColorTexture"] as? [String: Any]
        if baseTex == nil {
            // Older/alternative materials (Blender/Sketchfab exports
            // without PBR metallic-roughness) describe the base color via
            // the KHR_materials_pbrSpecularGlossiness extension. Without
            // this fallback, their texture stayed empty even though the
            // material has one.
            if let sg = ((mat["extensions"] as? [String: Any])?["KHR_materials_pbrSpecularGlossiness"]) as? [String: Any] {
                baseTex = sg["diffuseTexture"] as? [String: Any]
                if let diffuse = rgb(sg["diffuseFactor"]) { baseColor = diffuse }
            }
        }

        let (texBytes, texExt, texcoordSet) = textureBytes(gltf, buffers, texInfo: baseTex, sourceDir: sourceDir)
        let (mrBytes, _, _) = textureBytes(gltf, buffers, texInfo: pbr["metallicRoughnessTexture"] as? [String: Any], sourceDir: sourceDir)
        let (occBytes, _, _) = textureBytes(gltf, buffers, texInfo: mat["occlusionTexture"] as? [String: Any], sourceDir: sourceDir)
        let (normBytes, _, _) = textureBytes(gltf, buffers, texInfo: mat["normalTexture"] as? [String: Any], sourceDir: sourceDir)
        let (emisBytes, _, _) = textureBytes(gltf, buffers, texInfo: mat["emissiveTexture"] as? [String: Any], sourceDir: sourceDir)
        let emissiveFactor = rgb(mat["emissiveFactor"]) ?? SIMD3<Double>(0, 0, 0)

        // See MeshAtlas.channelHasRealContrast: a metallicRoughness texture
        // without a real spatial metal split (a generic AO/detail hint)
        // otherwise turns a completely matte material (Moon/Mars photo
        // textures) falsely into glossy metal when combined with an
        // unreflectively high metallicFactor.
        if let mrBytes, metallic > 0, !MeshAtlas.channelHasRealContrast(mrBytes, channel: 2) {
            metallic = 0
        }

        return MaterialInfo(
            texBytes: texBytes, texExt: texExt, flatRGB: baseColor, texcoordSet: texcoordSet,
            metallicFactor: metallic, roughnessFactor: roughness,
            metallicRoughnessTexBytes: mrBytes, occlusionTexBytes: occBytes,
            emissiveFactor: emissiveFactor, emissiveTexBytes: emisBytes, normalTexBytes: normBytes
        )
    }

    // MARK: - Primitive extraction

    private static func extractPrimitives(_ gltf: [String: Any], _ buffers: [Data], sourceDir: URL) -> [MeshAtlas.MeshPrimitive] {
        let nodes = (gltf["nodes"] as? [[String: Any]]) ?? []
        let meshes = (gltf["meshes"] as? [[String: Any]]) ?? []
        let scenes = (gltf["scenes"] as? [[String: Any]]) ?? []
        let sceneIndex = (gltf["scene"] as? Int) ?? 0
        let rootIndices: [Int]
        if sceneIndex < scenes.count, let roots = scenes[sceneIndex]["nodes"] as? [Int] {
            rootIndices = roots
        } else {
            rootIndices = Array(nodes.indices)
        }

        var primitives: [MeshAtlas.MeshPrimitive] = []
        var totalVertices = 0
        var statPrimitives = 0
        var statTextured = 0
        var statMaterials = 0
        var statSkipped = 0

        func visit(_ nodeIndex: Int, _ parentMatrix: simd_double4x4) {
            guard totalVertices < maxTotalVertices, nodeIndex >= 0, nodeIndex < nodes.count else { return }
            let node = nodes[nodeIndex]
            let world = parentMatrix * nodeLocalMatrix(node)

            if let meshIndex = node["mesh"] as? Int, meshIndex < meshes.count {
                for prim in (meshes[meshIndex]["primitives"] as? [[String: Any]]) ?? [] {
                    if totalVertices >= maxTotalVertices { break }
                    let mode = (prim["mode"] as? Int) ?? 4
                    guard mode == 4 else { // only TRIANGLES supported
                        statSkipped += 1
                        continue
                    }
                    let attrs = (prim["attributes"] as? [String: Any]) ?? [:]
                    guard let posAccessor = attrs["POSITION"] as? Int,
                          let positionsLocal = readAccessor(gltf, buffers, posAccessor) else { continue }
                    statPrimitives += 1
                    let materialIndex = prim["material"] as? Int
                    if materialIndex != nil { statMaterials += 1 }

                    let positions = positionsLocal.map { comps in
                        transformPoint(world, SIMD3<Double>(comps[0], comps[1], comps[2]))
                    }

                    var normals: [SIMD3<Double>]?
                    if let nrmAccessor = attrs["NORMAL"] as? Int,
                       let normalsLocal = readAccessor(gltf, buffers, nrmAccessor) {
                        normals = normalsLocal.map { comps in
                            normalize3(transformDir(world, SIMD3<Double>(comps[0], comps[1], comps[2])))
                        }
                    }

                    let info = materialInfo(gltf, buffers, materialIndex: materialIndex, sourceDir: sourceDir)
                    if info.texBytes != nil { statTextured += 1 }

                    // Prefers the UV set referenced by the material; falls
                    // back to TEXCOORD_0 if the primitive doesn't carry that
                    // set (a common authoring sloppiness).
                    var uvKey = "TEXCOORD_\(info.texcoordSet)"
                    if attrs[uvKey] == nil { uvKey = "TEXCOORD_0" }
                    var uvs: [SIMD2<Double>]?
                    if let uvAccessor = attrs[uvKey] as? Int,
                       let uvValues = readAccessor(gltf, buffers, uvAccessor) {
                        uvs = uvValues.map { SIMD2<Double>($0[0], $0[1]) }
                    }

                    var indices: [Int]
                    if let idxAccessor = prim["indices"] as? Int,
                       let idxValues = readAccessor(gltf, buffers, idxAccessor) {
                        indices = idxValues.map { Int($0[0]) }
                    } else {
                        indices = Array(0..<positions.count)
                    }

                    var resolvedNormals: [SIMD3<Double>]
                    if let normals {
                        resolvedNormals = normals
                    } else {
                        // No normals in the asset: average them from the triangles.
                        resolvedNormals = [SIMD3<Double>](repeating: .zero, count: positions.count)
                        var i = 0
                        while i + 2 < indices.count {
                            let ia = indices[i], ib = indices[i + 1], ic = indices[i + 2]
                            if ia < positions.count && ib < positions.count && ic < positions.count {
                                let fn = simd_cross(positions[ib] - positions[ia], positions[ic] - positions[ia])
                                resolvedNormals[ia] += fn
                                resolvedNormals[ib] += fn
                                resolvedNormals[ic] += fn
                            }
                            i += 3
                        }
                        resolvedNormals = resolvedNormals.map(normalize3)
                    }

                    let materialKey = materialIndex.map { "m\($0)" } ?? "none"
                    // A texture-less, NON-METALLIC material doesn't need
                    // PBR atlas treatment -- see UsdzImport.swift for the
                    // full rationale. Texture-less METALLIC materials stay
                    // on "pbr": many glTF exports leave metallicFactor
                    // unspecified (spec default 1.0), and the roughness-
                    // unaware "chrome" shader would always show them as
                    // mirror-smooth instead of with their real roughness.
                    let hasAnyTexture = info.texBytes != nil || info.metallicRoughnessTexBytes != nil
                        || info.occlusionTexBytes != nil || info.emissiveTexBytes != nil
                        || info.normalTexBytes != nil
                    let kind = (!hasAnyTexture && info.metallicFactor <= 0.5) ? "outer" : "pbr"
                    let primitive = MeshAtlas.MeshPrimitive(
                        positions: positions, normals: resolvedNormals, uvs: uvs,
                        indices: indices, kind: kind,
                        texBytes: info.texBytes, texExt: info.texExt,
                        flatRGB: info.flatRGB, materialKey: materialKey
                    )
                    primitive.metallicFactor = info.metallicFactor
                    primitive.roughnessFactor = info.roughnessFactor
                    primitive.metallicRoughnessTexBytes = info.metallicRoughnessTexBytes
                    primitive.occlusionTexBytes = info.occlusionTexBytes
                    primitive.emissiveFactor = info.emissiveFactor
                    primitive.emissiveTexBytes = info.emissiveTexBytes
                    primitive.normalTexBytes = info.normalTexBytes
                    primitives.append(primitive)
                    totalVertices += positions.count
                }
            }

            for child in (node["children"] as? [Int]) ?? [] {
                visit(child, world)
            }
        }

        for root in rootIndices {
            visit(root, matrix_identity_double4x4)
        }
        log("Primitives extracted: \(statPrimitives) (skipped non-triangle: \(statSkipped)), materials with texture: \(statTextured)/\(statMaterials), total vertices: \(totalVertices)")
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

    /// Converts the chosen .glb file into a cached OBJ+MTL.
    ///
    /// nil on any failure (missing file, broken format, no triangle
    /// geometry) -- the caller then falls back to the default model
    /// instead of crashing the screensaver.
    static func ensureGlbModel(sourcePath: String, bookmark: Data?) -> URL? {
        let scopedURL = MeshAtlas.startSecurityScopedAccess(bookmark: bookmark, log: log)
        defer { MeshAtlas.stopSecurityScopedAccess(scopedURL) }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            log("Source file not accessible: \(sourcePath)")
            return nil
        }
        return convertGlb(sourceURL)
    }

    private static func convertGlb(_ sourceURL: URL) -> URL? {
        guard let stat = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let size = stat[.size] as? Int,
              let mtime = stat[.modificationDate] as? Date else { return nil }
        let mtimeNs = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
        let keySource = "v\(meshVersion)|\(sourceURL.resolvingSymlinksInPath().path)|\(mtimeNs)|\(size)"
        let digest = Insecure.SHA1.hash(data: Data(keySource.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        let cache = cacheDir()
        let objPath = cache.appendingPathComponent("glb_\(key).obj")
        let mtlPath = cache.appendingPathComponent("glb_\(key).mtl")
        let fm = FileManager.default
        if fm.fileExists(atPath: objPath.path) && fm.fileExists(atPath: mtlPath.path) {
            return objPath
        }

        log("converting \(sourceURL.lastPathComponent) (\(size) bytes)")
        guard let data = try? Data(contentsOf: sourceURL),
              let (gltf, bin) = try? readGlb(data),
              let buffers = loadBuffers(gltf, bin: bin, sourceDir: sourceURL.deletingLastPathComponent()) else {
            return nil
        }
        let primitives = extractPrimitives(gltf, buffers, sourceDir: sourceURL.deletingLastPathComponent())
        guard !primitives.isEmpty else {
            log("no triangle primitives found -> fallback")
            return nil
        }

        var textureName: String?
        var pbrTextures: MeshAtlas.PBRTextureNames?
        var atlasRects: [String: (Double, Double, Double, Double)] = [:]
        if let atlases = MeshAtlas.buildPBRAtlases(primitives, log: log) {
            let baseColorName = "glb_\(key)_basecolor.png"
            let ormName = "glb_\(key)_orm.png"
            try? atlases.baseColorPNG.write(to: cache.appendingPathComponent(baseColorName))
            try? atlases.ormPNG.write(to: cache.appendingPathComponent(ormName))
            var emissiveName: String?
            if let emissivePNG = atlases.emissivePNG {
                emissiveName = "glb_\(key)_emissive.png"
                try? emissivePNG.write(to: cache.appendingPathComponent(emissiveName!))
            }
            var normalName: String?
            if let normalPNG = atlases.normalPNG {
                normalName = "glb_\(key)_normal.png"
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
                textureName = "glb_\(key)_texture\(texExt ?? ".png")"
                try? texBytes.write(to: cache.appendingPathComponent(textureName!))
                log("using texture from GLB material (\(texBytes.count) bytes, \(texExt ?? "?"))")
            } else if let flat = MeshAtlas.pickFlatColor(primitives) {
                textureName = "glb_\(key)_texture.png"
                MeshAtlas.writeSolidPNG(to: cache.appendingPathComponent(textureName!), rgb: flat)
                log("no texture found in the GLB -> synthetic flat color \(flat)")
            } else {
                log("no texture and no uniform flat color found -> default color (outer)")
            }
        }

        do {
            try MeshAtlas.writeObjMtl(
                primitives, objPath: objPath, mtlPath: mtlPath,
                textureName: textureName, pbrTextures: pbrTextures, atlasRects: atlasRects,
                prefix: "glb", sourceLabel: "GLB"
            )
        } catch {
            log("EXC writeObjMtl: \(error)")
            return nil
        }
        MeshAtlas.pruneCache(cacheDir: cache, objPrefix: "glb_", keep: keepCachedModels)
        return objPath
    }
}
