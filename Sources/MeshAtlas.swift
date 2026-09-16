import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// Shared building blocks for writing extracted 3D primitives into an
/// OBJ+MTL loadable by ModelIO -- including texture atlases for multi-
/// material models.
///
/// The Metal renderer only supports ONE global texture set per model
/// (see `TeapotMesh`), not one per submesh/material. To still give EVERY
/// material its real look, all materials of an imported model are merged
/// into SHARED texture atlases: each gets its own square cell (a real
/// texture scaled into it, or a flat fill in its flat/factor color), and
/// every primitive's UVs are remapped into its material's cell. All four
/// atlases (BaseColor, Occlusion/Roughness/Metallic, Emissive, Normal)
/// share the same cell layout, so a sample at the same UV position in all
/// four is guaranteed to belong to the same material.
///
/// Real pixel-for-pixel PBR shading (instead of a coarse chrome/non-chrome
/// triangle split as before) was necessary because the split mis-colored
/// whole parts on multi-material assets: a test spaceship's engine nacelles
/// (black with an orange ring pattern per the metallic texture) tipped
/// entirely into the uniform chrome shader and lost both texture AND color
/// -- immediately visible in Xcode's own (physically correct) USD preview.
/// With a real per-pixel metallic/roughness map, every part stays correct
/// independently of its neighbors.
///
/// Format-agnostic: both `GlbMesh` (GLB->OBJ) and `UsdzImport`
/// (USDZ/USD->OBJ) bring their source format into a list of
/// `MeshPrimitive` and call the same pipeline.
enum MeshAtlas {
    static let targetExtent: Double = 2.15 // matches TEAPOT_FIT_SCALE.
    static let atlasCellSize = 256   // MINIMUM pixel size per material cell.
    static let atlasMaxDim = 2048    // Upper bound on the atlas edge length.
    static let atlasMaxCells = 64    // Safety net against absurd material counts.

    // Tolerance for float noise at UV edges (e.g. 1.000000119 instead of 1.0).
    private static let uvEpsilon = 1e-4

    /// A triangle batch with a single material, format-independent.
    final class MeshPrimitive {
        var positions: [SIMD3<Double>]
        var normals: [SIMD3<Double>]
        var uvs: [SIMD2<Double>]?
        var indices: [Int]
        /// "pbr" (baseColor + optional ORM/emissive/normal textures, the
        /// normal case for imported GLB/USDZ models) | "outer" (no
        /// texture/UVs, flat color) | "chrome" (only relevant for manually
        /// created primitives, e.g. if a format ever delivers pure mirror
        /// chrome with no material info at all).
        var kind: String
        var texBytes: Data?
        var texExt: String?
        /// baseColorFactor/diffuseColor (linear), fallback flat color when
        /// no texture is present.
        var flatRGB: SIMD3<Double>
        /// Format-native material key (glTF index, material name, ...):
        /// groups primitives sharing a material into the same atlas cell
        /// instead of handling each one individually/redundantly.
        var materialKey: String

        // MARK: PBR extras (only evaluated when kind == "pbr")

        var metallicFactor: Double = 1.0
        var roughnessFactor: Double = 1.0
        /// glTF convention: G=Roughness, B=Metallic (R is often Occlusion,
        /// if the exporter packs it in).
        var metallicRoughnessTexBytes: Data?
        /// USD instead exports Metalness/Roughness/Occlusion as separate
        /// grayscale images (every channel identical) -- set as an
        /// alternative to `metallicRoughnessTexBytes`.
        var metallicTexBytes: Data?
        var roughnessTexBytes: Data?
        var occlusionTexBytes: Data?
        var emissiveFactor: SIMD3<Double> = SIMD3<Double>(0, 0, 0)
        var emissiveTexBytes: Data?
        var normalTexBytes: Data?

        init(positions: [SIMD3<Double>], normals: [SIMD3<Double>], uvs: [SIMD2<Double>]?,
             indices: [Int], kind: String, texBytes: Data?, texExt: String?,
             flatRGB: SIMD3<Double>, materialKey: String) {
            self.positions = positions
            self.normals = normals
            self.uvs = uvs
            self.indices = indices
            self.kind = kind
            self.texBytes = texBytes
            self.texExt = texExt
            self.flatRGB = flatRGB
            self.materialKey = materialKey
        }
    }

    // MARK: - UV handling

    /// Safely wraps UV coordinates into [0, 1] for the atlas cell remapping.
    ///
    /// Important: a plain modulo would map the VALID edge value 1.0 down to
    /// 0.0 -- for UV rects with the usual exact [0,1] range, that would
    /// collapse ALL four corners of a quad onto the same texel. Values
    /// SLIGHTLY outside that range (float noise, e.g. v=1.000000119 at the
    /// poles of a sphere) are CLAMPED to the edge instead of wrapped: modulo
    /// would let them jump to the OPPOSITE end of the texture, smearing the
    /// whole texture across the adjacent triangles (a visible seam on a
    /// sphere). Only genuine tiling well outside [0,1] is still wrapped.
    static func wrap01(_ x: Double) -> Double {
        if x >= 0.0 && x <= 1.0 { return x }
        if x >= -uvEpsilon && x < 0.0 { return 0.0 }
        if x > 1.0 && x <= 1.0 + uvEpsilon { return 1.0 }
        let m = x.truncatingRemainder(dividingBy: 1.0)
        return m < 0 ? m + 1.0 : m
    }

    /// Clamps (rather than wraps) into [0, 1] -- for UVs already made
    /// continuous per triangle (see `unwrapTriangleUV`), which can still be
    /// slightly out of range. Clamping instead of modulo avoids creating a
    /// NEW seam here.
    private static func clamp01(_ x: Double) -> Double {
        min(1.0, max(0.0, x))
    }

    /// Makes the U/V values of a triangle's three corners CONTINUOUS with
    /// each other.
    ///
    /// Some models deliberately let U/V run slightly past 1.0 at a texture
    /// seam (e.g. 1.003), so neighboring triangles sample seamlessly on the
    /// GPU. Wrapping PER CORNER INDEPENDENTLY tears such triangles apart: a
    /// corner at 1.003 becomes 0.003, while the neighboring corner at 0.996
    /// stays put -- the triangle gets stretched across almost the entire
    /// texture (a jagged tear along the seam, observed on the Moon model).
    /// Fix: take the most common integer floor of the three corners per axis
    /// as a reference and shift all corners TOGETHER -- their distance to
    /// each other is preserved.
    static func unwrapTriangleUV(_ corners: (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)) -> (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>) {
        func majorityFloor(_ vals: [Double]) -> Double {
            let floors = vals.map { $0.rounded(.down) }
            var counts: [Double: Int] = [:]
            for f in floors { counts[f, default: 0] += 1 }
            return counts.max { a, b in (a.value, -a.key) < (b.value, -b.key) }!.key
        }
        let uShift = -majorityFloor([corners.0.x, corners.1.x, corners.2.x])
        let vShift = -majorityFloor([corners.0.y, corners.1.y, corners.2.y])
        let shift = SIMD2<Double>(uShift, vShift)
        return (corners.0 + shift, corners.1 + shift, corners.2 + shift)
    }

    /// Encodes a LINEAR color channel (0..1) into sRGB gamma space.
    ///
    /// Flat colors (glTF baseColorFactor: linear per spec) are drawn into
    /// the atlas texture, which is loaded as an sRGB texture -- the GPU
    /// decodes sRGB -> linear on sample. Without this pre-encoding, an
    /// already-linear value would get decoded a SECOND time and appear
    /// visibly too dark. Real embedded texture images do NOT need this
    /// (already stored sRGB-encoded). Applies ONLY to color textures
    /// (BaseColor/Emissive) -- Occlusion/Roughness/Metallic and normal maps
    /// are linear data channels with no gamma and are never encoded here.
    static func linearToSRGB(_ c: Double) -> Double {
        let v = clamp01(c)
        if v <= 0.0031308 { return v * 12.92 }
        return 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    // MARK: - Synthetic flat-color texture

    static func writeSolidPNG(to url: URL, rgb: SIMD3<Double>) {
        guard let image = flatColorImage(rgb, srgbEncode: true, size: 4) else { return }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func flatColorImage(_ rgb: SIMD3<Double>, srgbEncode: Bool, size: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let r = srgbEncode ? linearToSRGB(rgb.x) : clamp01(rgb.x)
        let g = srgbEncode ? linearToSRGB(rgb.y) : clamp01(rgb.y)
        let b = srgbEncode ? linearToSRGB(rgb.z) : clamp01(rgb.z)
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    // MARK: - Scaling / selection

    static func fitScale(_ primitives: [MeshPrimitive]) -> (scale: Double, center: SIMD3<Double>) {
        var minP = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for prim in primitives {
            for p in prim.positions {
                minP = simd_min(minP, p)
                maxP = simd_max(maxP, p)
                any = true
            }
        }
        guard any else { return (1.0, SIMD3<Double>(0, 0, 0)) }
        let center = (minP + maxP) * 0.5
        let ext = maxP - minP
        let extent = max(ext.x, max(ext.y, ext.z))
        return (targetExtent / (extent > 0 ? extent : 1.0), center)
    }

    static func pickTexture(_ primitives: [MeshPrimitive]) -> (Data?, String?) {
        for prim in primitives where prim.texBytes != nil {
            return (prim.texBytes, prim.texExt)
        }
        return (nil, nil)
    }

    /// Only relevant as an absolute last resort (PBR atlas building
    /// practically never fails, unless CoreGraphics itself were broken) --
    /// returns a single flat color if REALLY all non-chrome primitives
    /// share the same one.
    static func pickFlatColor(_ primitives: [MeshPrimitive]) -> SIMD3<Double>? {
        var colors = Set<String>()
        var first: SIMD3<Double>?
        for prim in primitives where prim.kind != "chrome" {
            let key = String(format: "%.3f|%.3f|%.3f", prim.flatRGB.x, prim.flatRGB.y, prim.flatRGB.z)
            colors.insert(key)
            if first == nil { first = prim.flatRGB }
        }
        return colors.count == 1 ? first : nil
    }

    // MARK: - Image decoding

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Minimum contrast (max-min) above which a metallic image channel counts
    /// as a REAL spatial metal/non-metal split.
    ///
    /// Some asset packs (observed on a Moon/Mars photo-texture series)
    /// export a "metallicRoughness" texture for a completely non-metallic
    /// rock surface anyway, with narrow-band grayscale variation (basically
    /// a generic AO/detail hint) AND a high metallicFactor at the same time
    /// (0.8 for this Moon asset) -- without this check, that factor would
    /// turn the entire material into polished metal, even though Apple's
    /// own USD PBR pipeline (Xcode/SceneKit, verified via a SceneKit
    /// reference render) shows a completely matte result for a comparable
    /// Moon asset. A REAL metal mask (e.g. spaceship engines) separates
    /// sharply between near 0 and near 255 and has correspondingly high
    /// contrast.
    static let metallicMaskMinContrast = 80

    /// Does the given image channel (0=R,1=G,2=B) have enough contrast to
    /// carry real spatial information? Returns true when unsure (image not
    /// decodable) -- i.e. do NOT intervene, trust the author's data when in
    /// doubt.
    static func channelHasRealContrast(_ data: Data, channel: Int, sampleSize: Int = 48) -> Bool {
        guard let img = decodeImage(data) else { return true }
        var rgba = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: sampleSize, height: sampleSize, bitsPerComponent: 8,
                bytesPerRow: sampleSize * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        }
        var lo = 255
        var hi = 0
        for i in 0..<(sampleSize * sampleSize) {
            let v = Int(rgba[i * 4 + channel])
            lo = min(lo, v)
            hi = max(hi, v)
        }
        return (hi - lo) >= metallicMaskMinContrast
    }

    // MARK: - Shared atlas layout

    /// Layout (cell size, columns/rows, per-material UV rects) -- computed
    /// ONCE and reused for all four texture atlases (BaseColor, ORM,
    /// Emissive, Normal), so a sample at the same UV position in all four is
    /// guaranteed to belong to the same material.
    struct AtlasLayout {
        let order: [String]
        let cols: Int
        let rows: Int
        let cell: Int
        let atlasW: Int
        let atlasH: Int
        let rects: [String: (Double, Double, Double, Double)]
    }

    static func planAtlasLayout(_ primitives: [MeshPrimitive]) -> AtlasLayout? {
        var seen = Set<String>()
        var order: [String] = []
        var maxSrcDim = 0
        for prim in primitives where prim.kind != "chrome" {
            if seen.insert(prim.materialKey).inserted {
                order.append(prim.materialKey)
                if let texBytes = prim.texBytes, let img = decodeImage(texBytes) {
                    maxSrcDim = max(maxSrcDim, img.width, img.height)
                }
                if order.count >= atlasMaxCells { break }
            }
        }
        guard !order.isEmpty else { return nil }

        let cols = Int(ceil(sqrt(Double(order.count))))
        let rows = Int(ceil(Double(order.count) / Double(cols)))

        // Cell size adapts to the real texture resolution (a fixed 256px
        // cell visibly squashed e.g. 4096px textures), capped against
        // runaway atlas sizes.
        var cell = atlasCellSize
        if maxSrcDim > cell {
            cell = min(maxSrcDim, atlasMaxDim / max(cols, rows))
            cell = max(cell, atlasCellSize)
        }
        let atlasW = cols * cell
        let atlasH = rows * cell

        var rects: [String: (Double, Double, Double, Double)] = [:]
        for (i, matKey) in order.enumerated() {
            let col = i % cols
            let row = i / cols
            let topY = row * cell // top-left convention for the UV remapping
            rects[matKey] = (
                Double(col * cell) / Double(atlasW), Double(topY) / Double(atlasH),
                Double(cell) / Double(atlasW), Double(cell) / Double(atlasH)
            )
        }
        return AtlasLayout(order: order, cols: cols, rows: rows, cell: cell, atlasW: atlasW, atlasH: atlasH, rects: rects)
    }

    /// Draws ONE atlas image per `layout`: for each material, either the
    /// image `cellImage` provides (scaled into the cell) or, if nil, a flat
    /// fill in `cellFlatColor` (or `defaultColor` if that's also nil).
    private static func renderAtlas(
        layout: AtlasLayout,
        srgbEncodeFlat: Bool,
        defaultColor: SIMD3<Double>,
        cellImage: (String) -> CGImage?,
        cellFlatColor: (String) -> SIMD3<Double>?
    ) -> Data? {
        guard let ctx = CGContext(
            data: nil, width: layout.atlasW, height: layout.atlasH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for (i, matKey) in layout.order.enumerated() {
            let col = i % layout.cols
            let row = i / layout.cols
            let pxX = col * layout.cell
            let cgY = (layout.rows - 1 - row) * layout.cell // CGContext: origin bottom-left
            let rect = CGRect(x: pxX, y: cgY, width: layout.cell, height: layout.cell)

            if let img = cellImage(matKey) {
                ctx.draw(img, in: rect)
            } else {
                let rgb = cellFlatColor(matKey) ?? defaultColor
                let r = srgbEncodeFlat ? linearToSRGB(rgb.x) : clamp01(rgb.x)
                let g = srgbEncodeFlat ? linearToSRGB(rgb.y) : clamp01(rgb.y)
                let b = srgbEncodeFlat ? linearToSRGB(rgb.z) : clamp01(rgb.z)
                ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
                ctx.fill(rect)
            }
        }

        guard let atlasImage = ctx.makeImage() else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, atlasImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }

    // MARK: - Channel composition (Occlusion/Roughness/Metallic from separate
    // or glTF-packed source images, each multiplied by its factor)

    /// One channel (0=R,1=G,2=B) from `data`, scaled to `size`x`size` and
    /// multiplied by `factor` -- or, without an image, a flat fill with
    /// `factor` itself (glTF/USD convention: without a texture the factor
    /// IS the value).
    private static func sampleChannel(_ data: Data?, channel: Int, factor: Double, size: Int) -> [UInt8] {
        guard let data, let img = decodeImage(data) else {
            let v = UInt8(clamping: Int((clamp01(factor) * 255).rounded()))
            return [UInt8](repeating: v, count: size * size)
        }
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        var out = [UInt8](repeating: 0, count: size * size)
        let f = clamp01(factor)
        for i in 0..<(size * size) {
            let raw = Double(rgba[i * 4 + channel]) / 255.0
            out[i] = UInt8(clamping: Int((raw * f * 255).rounded()))
        }
        return out
    }

    private static func composeRGBImage(r: [UInt8], g: [UInt8], b: [UInt8], size: Int) -> CGImage? {
        var buf = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) {
            buf[i * 4 + 0] = r[i]
            buf[i * 4 + 1] = g[i]
            buf[i * 4 + 2] = b[i]
            buf[i * 4 + 3] = 255
        }
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Builds the Occlusion/Roughness/Metallic image of a single material
    /// (R=Occlusion, G=Roughness, B=Metallic -- like glTF's
    /// metallicRoughnessTexture convention, just extended with the
    /// occlusion channel). Covers both source forms: an already-packed
    /// glTF image OR USD's three separate grayscale images.
    private static func buildORMImage(for prim: MeshPrimitive, size: Int) -> CGImage? {
        let r: [UInt8]
        let g: [UInt8]
        let b: [UInt8]
        if let packed = prim.metallicRoughnessTexBytes {
            r = sampleChannel(prim.occlusionTexBytes, channel: 0, factor: 1.0, size: size)
            g = sampleChannel(packed, channel: 1, factor: prim.roughnessFactor, size: size)
            b = sampleChannel(packed, channel: 2, factor: prim.metallicFactor, size: size)
        } else {
            r = sampleChannel(prim.occlusionTexBytes, channel: 0, factor: 1.0, size: size)
            g = sampleChannel(prim.roughnessTexBytes, channel: 0, factor: prim.roughnessFactor, size: size)
            b = sampleChannel(prim.metallicTexBytes, channel: 0, factor: prim.metallicFactor, size: size)
        }
        return composeRGBImage(r: r, g: g, b: b, size: size)
    }

    private static func hasAnyORMTexture(_ prim: MeshPrimitive) -> Bool {
        prim.metallicRoughnessTexBytes != nil || prim.metallicTexBytes != nil
            || prim.roughnessTexBytes != nil || prim.occlusionTexBytes != nil
    }

    // MARK: - PBR atlases (BaseColor + ORM + Emissive + Normal)

    struct PBRAtlases {
        let baseColorPNG: Data
        let ormPNG: Data
        /// nil when NO primitive carries emission (saves a constant-black
        /// texture + sampling in the shader).
        let emissivePNG: Data?
        /// nil when NO primitive has a normal map -- the caller can then
        /// also skip the (more expensive) tangent generation.
        let normalPNG: Data?
        let rects: [String: (Double, Double, Double, Double)]
    }

    /// Builds all four atlases from a model's (non-chrome) primitives. nil
    /// on any failure (e.g. no materials) -- the caller then falls back to
    /// the old single-texture/flat-color path (`pickTexture`/
    /// `pickFlatColor`, without PBR shading).
    static func buildPBRAtlases(
        _ primitives: [MeshPrimitive],
        log: (String) -> Void = { _ in }
    ) -> PBRAtlases? {
        guard let layout = planAtlasLayout(primitives) else { return nil }

        var byKey: [String: MeshPrimitive] = [:]
        for prim in primitives where prim.kind != "chrome" {
            if byKey[prim.materialKey] == nil { byKey[prim.materialKey] = prim }
        }

        guard let baseColorPNG = renderAtlas(
            layout: layout, srgbEncodeFlat: true, defaultColor: SIMD3<Double>(0.75, 0.75, 0.78),
            cellImage: { key in byKey[key]?.texBytes.flatMap(decodeImage) },
            cellFlatColor: { key in byKey[key]?.flatRGB }
        ) else {
            log("buildPBRAtlases: BaseColor atlas failed")
            return nil
        }

        let ormSize = min(layout.cell, 512) // ORM doesn't need 2K resolution, saves memory/time.
        guard let ormPNG = renderAtlas(
            layout: layout, srgbEncodeFlat: false, defaultColor: SIMD3<Double>(1, 1, 0),
            cellImage: { key in byKey[key].flatMap { buildORMImage(for: $0, size: ormSize) } },
            cellFlatColor: { key in
                guard let p = byKey[key] else { return nil }
                return SIMD3<Double>(1.0, p.roughnessFactor, p.metallicFactor)
            }
        ) else {
            log("buildPBRAtlases: ORM atlas failed")
            return nil
        }

        let anyEmissive = byKey.values.contains { $0.emissiveTexBytes != nil || simd_length($0.emissiveFactor) > 1e-4 }
        let emissivePNG: Data? = anyEmissive ? renderAtlas(
            layout: layout, srgbEncodeFlat: true, defaultColor: SIMD3<Double>(0, 0, 0),
            cellImage: { key in byKey[key]?.emissiveTexBytes.flatMap(decodeImage) },
            cellFlatColor: { key in byKey[key]?.emissiveFactor }
        ) : nil

        let anyNormal = byKey.values.contains { $0.normalTexBytes != nil }
        let normalPNG: Data? = anyNormal ? renderAtlas(
            layout: layout, srgbEncodeFlat: false, defaultColor: SIMD3<Double>(0.5, 0.5, 1.0),
            cellImage: { key in byKey[key]?.normalTexBytes.flatMap(decodeImage) },
            cellFlatColor: { _ in SIMD3<Double>(0.5, 0.5, 1.0) }
        ) : nil

        log("PBR atlases built: \(layout.order.count) material(s), BaseColor \(baseColorPNG.count) bytes, ORM \(ormPNG.count) bytes, Emissive \(emissivePNG?.count ?? 0) bytes, Normal \(normalPNG?.count ?? 0) bytes")
        return PBRAtlases(baseColorPNG: baseColorPNG, ormPNG: ormPNG, emissivePNG: emissivePNG, normalPNG: normalPNG, rects: layout.rects)
    }

    // MARK: - OBJ/MTL generation

    /// Result of `buildPBRAtlases`, as file names for the MTL entry
    /// (already written next to the OBJ).
    struct PBRTextureNames {
        let baseColor: String
        let orm: String
        let emissive: String?
        let normal: String?
    }

    static func writeObjMtl(
        _ primitives: [MeshPrimitive],
        objPath: URL, mtlPath: URL,
        textureName: String?,
        pbrTextures: PBRTextureNames? = nil,
        atlasRects: [String: (Double, Double, Double, Double)],
        prefix: String, sourceLabel: String
    ) throws {
        let (scale, center) = fitScale(primitives)
        let stem = objPath.deletingPathExtension().lastPathComponent

        var groups: [String: [MeshPrimitive]] = ["chrome": [], "pbr": [], "outer": []]
        for prim in primitives {
            let kind = groups[prim.kind] != nil ? prim.kind : "outer"
            groups[kind]!.append(prim)
        }

        // "outer" gets its own newmtl entry per material identity instead of
        // a shared averaged color: a model with several flat colors (e.g. a
        // logo with a blue outer and a white inner face) would otherwise
        // merge into a single washed-out blended color.
        var outerNameByKey: [String: String] = [:]
        var outerColorByName: [String: SIMD3<Double>] = [:]
        for prim in groups["outer"]! where outerNameByKey[prim.materialKey] == nil {
            let name = "\(prefix)_outer_\(outerNameByKey.count)"
            outerNameByKey[prim.materialKey] = name
            outerColorByName[name] = prim.flatRGB
        }

        var vLines: [String] = []
        var vnLines: [String] = []
        var vtLines: [String] = []
        var faceBlocks: [(String, [String])] = []
        var vertexCount = 0

        for kind in ["outer", "chrome", "pbr"] {
            let prims = groups[kind]!
            if prims.isEmpty { continue }
            var facesByName: [String: [String]] = [:]
            var faceNameOrder: [String] = []
            for prim in prims {
                let materialName = kind == "outer" ? outerNameByKey[prim.materialKey]! : "\(prefix)_\(kind)"
                if facesByName[materialName] == nil {
                    facesByName[materialName] = []
                    faceNameOrder.append(materialName)
                }
                let baseIndex = vertexCount
                for p in prim.positions {
                    vLines.append(String(
                        format: "v %.6f %.6f %.6f",
                        (p.x - center.x) * scale, (p.y - center.y) * scale, (p.z - center.z) * scale
                    ))
                }
                for n in prim.normals {
                    vnLines.append(String(format: "vn %.6f %.6f %.6f", n.x, n.y, n.z))
                }
                vertexCount += prim.positions.count

                let cell = kind != "chrome" ? atlasRects[prim.materialKey] : nil

                // Write UVs per FACE CORNER (not per vertex): a vertex can be
                // shared by multiple triangles that need to be unwrapped
                // DIFFERENTLY at a texture seam (see unwrapTriangleUV) -- a
                // single shared "vt" entry per vertex couldn't represent
                // both sides correctly.
                var i = 0
                while i + 2 < prim.indices.count {
                    let iaLocal = prim.indices[i]
                    let ibLocal = prim.indices[i + 1]
                    let icLocal = prim.indices[i + 2]
                    let ia = baseIndex + iaLocal + 1
                    let ib = baseIndex + ibLocal + 1
                    let ic = baseIndex + icLocal + 1

                    var corners: [SIMD2<Double>?] = [nil, nil, nil]
                    if let uvs = prim.uvs, iaLocal < uvs.count, ibLocal < uvs.count, icLocal < uvs.count {
                        let unwrapped = unwrapTriangleUV((uvs[iaLocal], uvs[ibLocal], uvs[icLocal]))
                        corners = [unwrapped.0, unwrapped.1, unwrapped.2]
                    }

                    var vtIndices: [Int] = []
                    for cornerUV in corners {
                        if let (u0, v0Top, cw, ch) = cell {
                            let au: Double
                            let avTop: Double
                            if let uv = cornerUV {
                                au = u0 + clamp01(uv.x) * cw
                                avTop = v0Top + clamp01(uv.y) * ch
                            } else {
                                // No UVs on the primitive: cell center ->
                                // representative color instead of the atlas
                                // corner.
                                au = u0 + 0.5 * cw
                                avTop = v0Top + 0.5 * ch
                            }
                            vtLines.append(String(format: "vt %.6f %.6f", au, 1.0 - avTop))
                        } else if let uv = cornerUV {
                            vtLines.append(String(format: "vt %.6f %.6f", uv.x, 1.0 - uv.y))
                        } else {
                            vtLines.append("vt 0.0 0.0")
                        }
                        vtIndices.append(vtLines.count)
                    }

                    facesByName[materialName]!.append("f \(ia)/\(vtIndices[0])/\(ia) \(ib)/\(vtIndices[1])/\(ib) \(ic)/\(vtIndices[2])/\(ic)")
                    i += 3
                }
            }
            for name in faceNameOrder {
                faceBlocks.append((name, facesByName[name]!))
            }
        }

        var lines = ["# Converted from \(sourceLabel) (\(stem))", "mtllib \(stem).mtl", "o \(stem)", ""]
        lines.append(contentsOf: vLines)
        lines.append("")
        lines.append(contentsOf: vtLines)
        lines.append("")
        lines.append(contentsOf: vnLines)
        lines.append("")
        for (name, faces) in faceBlocks where !faces.isEmpty {
            lines.append("usemtl \(name)")
            lines.append(contentsOf: faces)
            lines.append("")
        }
        let objText = lines.joined(separator: "\n") + "\n"

        var mtlLines = ["# Converted from \(sourceLabel)"]
        let hasKind: (String) -> Bool = { name in
            faceBlocks.contains { $0.0 == name && !$0.1.isEmpty }
        }
        for name in outerNameByKey.values.sorted() where hasKind(name) {
            // flatRGB is linear (glTF baseColorFactor/USD diffuseColor are,
            // per spec) -- encode to sRGB so Kd delivers the same directly-
            // consumed value as in the bundled .mtl files (mesh_col_fs does
            // no color-space conversion itself, see "chrome" below).
            let color = outerColorByName[name] ?? SIMD3<Double>(0.75, 0.75, 0.78)
            let kd = String(format: "%.4f %.4f %.4f", linearToSRGB(color.x), linearToSRGB(color.y), linearToSRGB(color.z))
            mtlLines += ["newmtl \(name)", "Kd \(kd)", "Ks 0"]
        }
        if hasKind("\(prefix)_chrome") {
            let chromePrims = groups["chrome"]!
            var avg = SIMD3<Double>(1, 1, 1)
            if !chromePrims.isEmpty {
                avg = chromePrims.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.flatRGB } / Double(chromePrims.count)
            }
            let kd = String(format: "%.4f %.4f %.4f", linearToSRGB(avg.x), linearToSRGB(avg.y), linearToSRGB(avg.z))
            mtlLines += ["newmtl \(prefix)_chrome", "Kd \(kd)", "Ks 1", "Ns 900"]
        }
        if hasKind("\(prefix)_pbr") {
            mtlLines += ["newmtl \(prefix)_pbr", "Kd 1 1 1", "Ks 1"]
            if let pbrTextures {
                // map_Kd = BaseColor (standard OBJ line, ModelIO reads it).
                // The other three are NOT an official OBJ/MTL convention --
                // custom, self-parsed lines (see TeapotMesh.swift), since
                // OBJ/MTL has no PBR format.
                mtlLines.append("map_Kd \(pbrTextures.baseColor)")
                mtlLines.append("map_ORM \(pbrTextures.orm)")
                if let emissive = pbrTextures.emissive {
                    mtlLines.append("map_Emissive \(emissive)")
                }
                if let normal = pbrTextures.normal {
                    mtlLines.append("map_Normal \(normal)")
                }
            } else if let textureName {
                // Fallback path without PBR atlases (Quartz failure or
                // similar): BaseColor only, as before.
                mtlLines.append("map_Kd \(textureName)")
            }
        }
        try (mtlLines.joined(separator: "\n") + "\n").write(to: mtlPath, atomically: true, encoding: .utf8)

        // Write the .obj ATOMICALLY last: the caller's cache-hit check only
        // checks file existence -- without atomicity, a SECOND concurrent
        // load (e.g. preview + full-screen, or the rendering + raycast mesh
        // shortly after each other) could read the file half-written (a
        // face referencing past the end of the still-incomplete vertex list
        // -> load failure). `.atomically` provides the needed
        // temp-file+rename pattern.
        try objText.write(to: objPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Security-scoped bookmarks

    /// Activates sandbox access to a file chosen via NSOpenPanel.
    ///
    /// The Options dialog (which presents the NSOpenPanel) and the running
    /// screensaver are DIFFERENT process instances. Without a security-
    /// scoped bookmark, the screensaver process immediately loses access
    /// again to a file outside its container (reading fails even though the
    /// file exists). Returns the resolved URL (to stop access later) or nil.
    static func startSecurityScopedAccess(bookmark: Data?, log: (String) -> Void = { _ in }) -> URL? {
        guard let bookmark, !bookmark.isEmpty else { return nil }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if url.startAccessingSecurityScopedResource() {
                return url
            }
            log("startAccessingSecurityScopedResource returned false")
        } catch {
            log("Bookmark resolution failed: \(error)")
        }
        return nil
    }

    static func stopSecurityScopedAccess(_ url: URL?) {
        url?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Cache

    /// Keeps only the `keep` most recent cached models (by mtime).
    ///
    /// `objPrefix` selects the .obj main files (e.g. "glb_"); the
    /// associated .mtl/texture/atlas files share the file-name stem and are
    /// deleted alongside via a stem-prefix match (texture files are named
    /// "<stem>_texture.png"/"<stem>_atlas.png" -- a pattern matching only
    /// "stem.*" would never catch them, a cache leak).
    static func pruneCache(cacheDir: URL, objPrefix: String, keep: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let objs = entries
            .filter { $0.pathExtension == "obj" && $0.lastPathComponent.hasPrefix(objPrefix) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for old in objs.dropFirst(keep) {
            let stem = old.deletingPathExtension().lastPathComponent
            for entry in entries where entry.lastPathComponent.hasPrefix(stem) {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Diagnostic log

    /// Diagnostic log under ~/Library/Logs (one entry per conversion thanks
    /// to caching) -- helps figure out, without reopening the source file,
    /// which material/texture path was taken.
    static func makeLogger(tag: String) -> (String) -> Void {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Matrix3DSaverX.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        return { msg in
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            let line = "\(df.string(from: Date())) pid=\(pid) [\(tag)] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
