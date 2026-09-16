import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import simd

/// Runtime generator: arbitrary text -> extruded 3D model (OBJ+MTL).
///
/// Every installed TrueType font serves as a "3D character set": Core Text
/// returns the glyph outlines directly as `CGPath` -- the curves are
/// flattened, triangulated via a hand-written ear-clipping triangulator with
/// hole support (deliberately without an external package, see
/// `EarClipTriangulator`), and extruded with side walls. The caps get the
/// chrome material, the sides the blue base material -- the same naming
/// convention as the R@lle logo ("text_chrome"/"text_outer"), so
/// `TeapotMesh`'s submesh classification (material name contains "chrome")
/// keeps working unchanged.
///
/// The generated files land in a cache under Application Support; the file
/// name contains a hash of text+font, so changed text automatically
/// produces a new model.
enum TextMeshGenerator {
    static let targetWidth: CGFloat = 3.2
    static let targetHeight: CGFloat = 0.962292
    // Target dimensions exactly matching ralle_logo, so all models have the
    // same order of magnitude in the Renderer.
    static let targetDepth: CGFloat = 0.36
    static let curveTolerance: CGFloat = 2.0

    static let fontCandidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Verdana Bold.ttf",
        "/System/Library/Fonts/Supplemental/Tahoma Bold.ttf",
    ]

    // Bump on changes to mesh generation, so old (possibly broken) cache
    // files don't keep getting reused.
    private static let meshVersion = 2
    private static let keepCachedModels = 8

    private static func fontPath() -> String? {
        fontCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func cacheDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Matrix3DSaverX/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Flattening Bezier curves

    private static func quadPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(x: mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
                       y: mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y)
    }

    private static func cubicPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x,
            y: mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y
        )
    }

    private static func dist2(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func flattenQuadratic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, tol: CGFloat, out: inout [CGPoint]) {
        let midCurve = quadPoint(p0, p1, p2, 0.5)
        let midChord = CGPoint(x: (p0.x + p2.x) * 0.5, y: (p0.y + p2.y) * 0.5)
        if dist2(midCurve, midChord) <= tol * tol {
            out.append(p2)
            return
        }
        let q01 = CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
        let q12 = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
        let qmid = CGPoint(x: (q01.x + q12.x) * 0.5, y: (q01.y + q12.y) * 0.5)
        flattenQuadratic(p0, q01, qmid, tol: tol, out: &out)
        flattenQuadratic(qmid, q12, p2, tol: tol, out: &out)
    }

    private static func flattenCubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, tol: CGFloat, out: inout [CGPoint]) {
        let midCurve = cubicPoint(p0, p1, p2, p3, 0.5)
        let midChord = CGPoint(x: (p0.x + p3.x) * 0.5, y: (p0.y + p3.y) * 0.5)
        if dist2(midCurve, midChord) <= tol * tol {
            out.append(p3)
            return
        }
        let p01 = CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
        let p12 = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
        let p23 = CGPoint(x: (p2.x + p3.x) * 0.5, y: (p2.y + p3.y) * 0.5)
        let p012 = CGPoint(x: (p01.x + p12.x) * 0.5, y: (p01.y + p12.y) * 0.5)
        let p123 = CGPoint(x: (p12.x + p23.x) * 0.5, y: (p12.y + p23.y) * 0.5)
        let p0123 = CGPoint(x: (p012.x + p123.x) * 0.5, y: (p012.y + p123.y) * 0.5)
        flattenCubic(p0, p01, p012, p0123, tol: tol, out: &out)
        flattenCubic(p0123, p123, p23, p3, tol: tol, out: &out)
    }

    private static func flattenPath(_ path: CGPath, tolerance: CGFloat) -> [[CGPoint]] {
        var contours: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start: CGPoint?
        var last = CGPoint.zero

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                if !current.isEmpty { contours.append(current) }
                let p = element.points[0]
                current = [p]
                start = p
                last = p
            case .addLineToPoint:
                let p = element.points[0]
                current.append(p)
                last = p
            case .addQuadCurveToPoint:
                let ctrl = element.points[0]
                let end = element.points[1]
                flattenQuadratic(last, ctrl, end, tol: tolerance, out: &current)
                last = end
            case .addCurveToPoint:
                let c1 = element.points[0], c2 = element.points[1], end = element.points[2]
                flattenCubic(last, c1, c2, end, tol: tolerance, out: &current)
                last = end
            case .closeSubpath:
                if let s = start, current.last != s { current.append(s) }
            @unknown default:
                break
            }
        }
        if !current.isEmpty { contours.append(current) }
        return contours
    }

    // MARK: - Collecting glyphs

    private static func collectGlyphs(text: String, fontPath: String) -> (glyphs: [[[CGPoint]]], bounds: (CGFloat, CGFloat, CGFloat, CGFloat)?) {
        guard let dataProvider = CGDataProvider(filename: fontPath),
              let cgFont = CGFont(dataProvider) else {
            return ([], nil)
        }
        let font = CTFontCreateWithGraphicsFont(cgFont, 1000, nil, nil)

        var glyphsOut: [[[CGPoint]]] = []
        var x: CGFloat = 0
        for scalar in text.unicodeScalars {
            guard let uniChar = UniChar(exactly: scalar.value) else { continue }
            var chars = [uniChar]
            var glyph: CGGlyph = 0
            let ok = CTFontGetGlyphsForCharacters(font, &chars, &glyph, 1)
            guard ok, glyph != 0 else { continue }

            var advance = CGSize.zero
            var glyphForAdvance = glyph
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphForAdvance, &advance, 1)

            if let cgPath = CTFontCreatePathForGlyph(font, glyph, nil) {
                var transform = CGAffineTransform(translationX: x, y: 0)
                if let translated = cgPath.copy(using: &transform) {
                    glyphsOut.append(flattenPath(translated, tolerance: curveTolerance))
                }
            }
            x += advance.width
        }

        let allPoints = glyphsOut.flatMap { $0.flatMap { $0 } }
        guard !allPoints.isEmpty else { return (glyphsOut, nil) }
        let xs = allPoints.map(\.x)
        let ys = allPoints.map(\.y)
        return (glyphsOut, (xs.min()!, ys.min()!, xs.max()!, ys.max()!))
    }

    // MARK: - Outer contour / hole grouping

    private static func signedArea(_ contour: [CGPoint]) -> CGFloat {
        guard contour.count > 1 else { return 0 }
        var area: CGFloat = 0
        for i in 0..<(contour.count - 1) {
            let p0 = contour[i], p1 = contour[i + 1]
            area += p0.x * p1.y - p1.x * p0.y
        }
        return area * 0.5
    }

    private static func pointInRing(_ pt: CGPoint, _ ring: [CGPoint]) -> Bool {
        let n = (ring.first == ring.last) ? ring.count - 1 : ring.count
        guard n > 0 else { return false }
        var inside = false
        for i in 0..<n {
            let p0 = ring[i]
            let p1 = ring[(i + 1) % n]
            if (p0.y > pt.y) != (p1.y > pt.y) {
                let t = (pt.y - p0.y) / (p1.y - p0.y)
                if pt.x < p0.x + t * (p1.x - p0.x) {
                    inside.toggle()
                }
            }
        }
        return inside
    }

    /// Group outer contours with their holes (umlaut dots, the dot on an i,
    /// etc. are extra outer contours; B/8/@ have holes). Orientation (sign
    /// of the signed area) distinguishes outer/inner; each hole gets
    /// assigned to the smallest outer contour that contains it.
    private static func groupRings(_ contours: [[CGPoint]]) -> [(outer: [CGPoint], holes: [[CGPoint]])] {
        let rings = contours.filter { $0.count >= 4 }
        guard !rings.isEmpty else { return [] }
        let areas = rings.map(signedArea)
        let largest = areas.indices.max { abs(areas[$0]) < abs(areas[$1]) }!
        let outerPositive = areas[largest] >= 0

        var groups: [(outer: [CGPoint], holes: [[CGPoint]])] = []
        var holes: [[CGPoint]] = []
        for (ring, area) in zip(rings, areas) {
            if (area >= 0) == outerPositive {
                groups.append((ring, []))
            } else {
                holes.append(ring)
            }
        }

        for hole in holes {
            guard let pt = hole.first else { continue }
            var best: Int?
            var bestArea: CGFloat = .greatestFiniteMagnitude
            for (gi, group) in groups.enumerated() where pointInRing(pt, group.outer) {
                let outerArea = abs(signedArea(group.outer))
                if outerArea < bestArea {
                    best = gi
                    bestArea = outerArea
                }
            }
            if let best {
                groups[best].holes.append(hole)
            }
            // A hole with no enclosing outer contour: discard (degenerate data).
        }
        return groups
    }

    // MARK: - Triangulation (outer contour + holes)

    private static func triangulateRingGroup(outer: [CGPoint], holes: [[CGPoint]]) -> (points: [CGPoint], tris: [(Int, Int, Int)]) {
        var points: [CGPoint] = []
        func addRing(_ ring: [CGPoint]) -> [Int] {
            let pts = (ring.first == ring.last) ? Array(ring.dropLast()) : ring
            let start = points.count
            points.append(contentsOf: pts)
            return Array(start..<points.count)
        }
        let outerIndices = addRing(outer)
        let holeIndexLists = holes.map(addRing)
        guard !points.isEmpty else { return ([], []) }

        let merged = EarClipTriangulator.mergeHoles(outer: outerIndices, holes: holeIndexLists, points: points)
        let tris = EarClipTriangulator.triangulate(merged, points: points)
        return (points, tris)
    }

    // MARK: - Mesh construction

    private static func faceNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let n = cross(b - a, c - a)
        let len = length(n)
        return len > 0 ? n / len : SIMD3<Float>(0, 0, 1)
    }

    private final class MeshBuilder {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var facesOuter: [(Int, Int, Int)] = []
        var facesChrome: [(Int, Int, Int)] = []

        func addVertex(_ pos: SIMD3<Float>, _ normal: SIMD3<Float>) -> Int {
            vertices.append(pos)
            normals.append(normal)
            return vertices.count // 1-based (OBJ convention)
        }

        func addCap(points: [CGPoint], z: CGFloat, normal: SIMD3<Float>, tris: [(Int, Int, Int)]) {
            let localIndices = points.map { addVertex(SIMD3<Float>(Float($0.x), Float($0.y), Float(z)), normal) }
            let flip = normal.z < 0
            for (a, b, c) in tris {
                guard a < localIndices.count, b < localIndices.count, c < localIndices.count else { continue }
                if flip {
                    facesChrome.append((localIndices[a], localIndices[c], localIndices[b]))
                } else {
                    facesChrome.append((localIndices[a], localIndices[b], localIndices[c]))
                }
            }
        }

        func addSides(contours: [[CGPoint]], halfDepth: CGFloat) {
            for contour in contours {
                guard contour.count >= 2 else { continue }
                let pts = (contour.first == contour.last) ? Array(contour.dropLast()) : contour
                guard pts.count >= 2 else { continue }
                for i in 0..<pts.count {
                    let p0 = pts[i]
                    let p1 = pts[(i + 1) % pts.count]
                    let v0 = addVertex(SIMD3<Float>(Float(p0.x), Float(p0.y), Float(halfDepth)), SIMD3<Float>(0, 0, 1))
                    let v1 = addVertex(SIMD3<Float>(Float(p1.x), Float(p1.y), Float(halfDepth)), SIMD3<Float>(0, 0, 1))
                    let v2 = addVertex(SIMD3<Float>(Float(p1.x), Float(p1.y), Float(-halfDepth)), SIMD3<Float>(0, 0, -1))
                    let v3 = addVertex(SIMD3<Float>(Float(p0.x), Float(p0.y), Float(-halfDepth)), SIMD3<Float>(0, 0, -1))
                    let n = faceNormal(vertices[v0 - 1], vertices[v1 - 1], vertices[v2 - 1])
                    for idx in [v0, v1, v2, v3] { normals[idx - 1] = n }
                    facesOuter.append((v0, v1, v2))
                    facesOuter.append((v0, v2, v3))
                }
            }
        }
    }

    private static func transformPoints(_ glyphs: [[[CGPoint]]], bounds: (CGFloat, CGFloat, CGFloat, CGFloat)) -> [[[CGPoint]]] {
        let (minX, minY, maxX, maxY) = bounds
        let srcW = max(1e-6, maxX - minX)
        let srcH = max(1e-6, maxY - minY)
        // Clamp both width AND height: long text fills the width, single
        // characters fill the height -- nothing blows out the composition.
        let scale = min(targetWidth / srcW, targetHeight / srcH)
        let cx = (minX + maxX) * 0.5
        let cy = (minY + maxY) * 0.5
        return glyphs.map { glyph in
            glyph.map { contour in
                contour.map { p in CGPoint(x: (p.x - cx) * scale, y: (p.y - cy) * scale) }
            }
        }
    }

    private static func buildMesh(_ glyphs: [[[CGPoint]]]) -> MeshBuilder {
        let halfDepth = targetDepth * 0.5
        let builder = MeshBuilder()
        for contours in glyphs {
            var madeCaps = false
            for group in groupRings(contours) {
                let (points, tris) = triangulateRingGroup(outer: group.outer, holes: group.holes)
                guard !points.isEmpty, !tris.isEmpty else { continue }
                builder.addCap(points: points, z: halfDepth, normal: SIMD3<Float>(0, 0, 1), tris: tris)
                builder.addCap(points: points, z: -halfDepth, normal: SIMD3<Float>(0, 0, -1), tris: tris)
                madeCaps = true
            }
            if madeCaps {
                // Raw contours: addSides receives outer and hole contours
                // unchanged, without prior triangulation.
                builder.addSides(contours: contours, halfDepth: halfDepth)
            }
        }
        return builder
    }

    // MARK: - Writing OBJ/MTL

    private static func writeOBJ(_ builder: MeshBuilder, objURL: URL) throws {
        let stem = objURL.deletingPathExtension().lastPathComponent
        var lines = ["# 3D text (\(stem))", "mtllib \(stem).mtl", "o \(stem)", ""]
        for v in builder.vertices {
            lines.append(String(format: "v %.6f %.6f %.6f", v.x, v.y, v.z))
        }
        lines.append("")
        for n in builder.normals {
            lines.append(String(format: "vn %.6f %.6f %.6f", n.x, n.y, n.z))
        }
        lines.append("")

        func emitFaces(_ material: String, _ faces: [(Int, Int, Int)]) {
            guard !faces.isEmpty else { return }
            lines.append("usemtl text_\(material)")
            for (a, b, c) in faces {
                lines.append("f \(a)//\(a) \(b)//\(b) \(c)//\(c)")
            }
            lines.append("")
        }
        emitFaces("outer", builder.facesOuter)
        emitFaces("chrome", builder.facesChrome)

        try (lines.joined(separator: "\n") + "\n").write(to: objURL, atomically: true, encoding: .utf8)
    }

    private static func writeMTL(_ mtlURL: URL) throws {
        let text = """
        # 3D text
        newmtl text_outer
        Kd 0.00 0.02 0.42
        Ks 0
        newmtl text_chrome
        Kd 1 1 1
        Ks 1
        Ns 900

        """
        try text.write(to: mtlURL, atomically: true, encoding: .utf8)
    }

    private static func pruneCache(_ cache: URL, keep: Int = keepCachedModels) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let objs = files.filter { $0.pathExtension == "obj" && $0.lastPathComponent.hasPrefix("text_") }
        let sorted = objs.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }
        for old in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("mtl"))
        }
    }

    // MARK: - Public API

    /// Returns the OBJ path for the text; generates the model on demand.
    /// nil if no representable character is contained, or none of the
    /// candidate fonts exist -- the caller then falls back to the default
    /// model.
    static func ensureTextModel(text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let fontPath = fontPath() else { return nil }

        let hashInput = "v\(meshVersion)|\(fontPath)|\(trimmed)"
        let digest = Insecure.SHA1.hash(data: Data(hashInput.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(12)

        let cache = cacheDir()
        let objURL = cache.appendingPathComponent("text_\(key).obj")
        let mtlURL = cache.appendingPathComponent("text_\(key).mtl")
        if FileManager.default.fileExists(atPath: objURL.path), FileManager.default.fileExists(atPath: mtlURL.path) {
            return objURL
        }

        let (glyphs, bounds) = collectGlyphs(text: trimmed, fontPath: fontPath)
        guard let bounds else { return nil }
        let transformed = transformPoints(glyphs, bounds: bounds)
        let builder = buildMesh(transformed)
        guard !builder.vertices.isEmpty else { return nil }

        do {
            try writeMTL(mtlURL)
            try writeOBJ(builder, objURL: objURL)
        } catch {
            NSLog("[Matrix3DSaverX] 3D text generation failed: \(error)")
            return nil
        }
        pruneCache(cache)
        return objURL
    }
}
