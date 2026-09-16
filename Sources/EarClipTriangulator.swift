import CoreGraphics

/// Triangulation of polygons with holes, with no external package at all.
///
/// Two-stage approach, as used internally by earcut.js:
/// 1. `mergeHoles`: each hole is stitched into the outer contour via a
///    "bridge" (two coincident edges), until only a single (hole-free)
///    polygon remains -- a degenerate zero-width channel that doesn't
///    visibly affect the triangulation.
/// 2. `triangulate`: ear clipping on the resulting polygon.
///
/// IMPORTANT -- this was the root cause of large parts of the caps being
/// missing for ALL letters with holes (~38% of the cap area was missing):
/// the stitched-together polygon inevitably contains DUPLICATE points,
/// since every bridge endpoint exists twice with identical coordinates. A
/// naive ear test then rejects every ear that touches such a duplicate
/// (the point lies "inside" the triangle -- namely exactly on a corner),
/// until no ear can be found at all and the rest of the polygon would be
/// silently discarded. Index comparisons ("this edge belongs to this
/// endpoint") likewise fail when stitching in the SECOND hole, because the
/// same index then appears multiple times in the polygon. That's why this
/// code works coordinate-based with tolerances everywhere: coincident
/// points don't block an ear, degenerate (collinear) corners are removed
/// instead of blocking, splice positions are array positions rather than
/// index values, and instead of a silent abort there's a fallback so the
/// complete polygon always gets triangulated.
enum EarClipTriangulator {
    /// Coordinates lie within a few units after scaling; font rounding
    /// errors are orders of magnitude smaller.
    private static let coordEps: CGFloat = 1e-9
    private static let areaEps: CGFloat = 1e-12

    private static func samePoint(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) <= coordEps && abs(a.y - b.y) <= coordEps
    }

    // MARK: - Stitching in holes

    /// Inserts all `holes` into `outer` and returns the resulting index
    /// sequence of a single polygon (with degenerate bridge channels).
    static func mergeHoles(outer: [Int], holes: [[Int]], points: [CGPoint]) -> [Int] {
        var merged = outer
        // Stitch in holes further to the right first (like earcut.js) --
        // more robust with multiple holes in one contour.
        let orderedHoles = holes.sorted { holeMaxX($0, points: points) > holeMaxX($1, points: points) }
        for hole in orderedHoles where !hole.isEmpty {
            guard let bridge = findBridge(hole: hole, merged: merged, points: points) else { continue }
            merged = splice(merged: merged, bridgePos: bridge.mergedPos, hole: hole, anchorPos: bridge.holePos)
        }
        return merged
    }

    private static func holeMaxX(_ hole: [Int], points: [CGPoint]) -> CGFloat {
        hole.map { points[$0].x }.max() ?? -.greatestFiniteMagnitude
    }

    /// Finds a valid bridge between a hole and the current polygon.
    /// Returns POSITIONS in the respective arrays (not index values --
    /// those are no longer unique after the first stitch).
    ///
    /// A bridge is valid if it crosses no edge of the polygon or the hole
    /// AND its midpoint lies inside the polygon (per the Jordan curve
    /// theorem, a crossing-free segment lies either entirely inside or
    /// entirely outside -- for concave letters like B/a/8 it could
    /// otherwise run entirely outside through an indentation).
    private static func findBridge(hole: [Int], merged: [Int], points: [CGPoint]) -> (holePos: Int, mergedPos: Int)? {
        guard merged.count >= 3 else { return nil }
        let holeOrder = hole.indices.sorted { points[hole[$0]].x > points[hole[$1]].x }
        for hp in holeOrder {
            let m = points[hole[hp]]
            let candOrder = merged.indices.sorted {
                distance2(points[merged[$0]], m) < distance2(points[merged[$1]], m)
            }
            for cp in candOrder {
                let c = points[merged[cp]]
                if samePoint(m, c) { continue }
                if crossesAnyEdge(m, c, loop: merged, points: points) { continue }
                if crossesAnyEdge(m, c, loop: hole, points: points) { continue }
                let mid = CGPoint(x: (m.x + c.x) / 2, y: (m.y + c.y) / 2)
                if pointInPolygon(mid, polygon: merged, points: points) {
                    return (hp, cp)
                }
            }
        }
        return nil
    }

    /// Does the bridge (a-b) cross any edge of `loop`? Edges touching a
    /// bridge endpoint don't count (coordinate-based).
    private static func crossesAnyEdge(_ a: CGPoint, _ b: CGPoint, loop: [Int], points: [CGPoint]) -> Bool {
        let n = loop.count
        guard n >= 2 else { return false }
        for i in 0..<n {
            let p1 = points[loop[i]]
            let p2 = points[loop[(i + 1) % n]]
            if samePoint(p1, a) || samePoint(p2, a) || samePoint(p1, b) || samePoint(p2, b) { continue }
            if segmentsIntersect(a, b, p1, p2) { return true }
        }
        return false
    }

    /// Point-in-polygon via ray casting (even-odd rule). Robust against the
    /// degenerate bridge channels: their duplicate edges get counted twice
    /// and don't change the parity.
    private static func pointInPolygon(_ point: CGPoint, polygon: [Int], points: [CGPoint]) -> Bool {
        var inside = false
        let n = polygon.count
        var j = n - 1
        for i in 0..<n {
            let pi = points[polygon[i]]
            let pj = points[polygon[j]]
            if (pi.y > point.y) != (pj.y > point.y) {
                let x = pi.x + (point.y - pi.y) * (pj.x - pi.x) / (pj.y - pi.y)
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Stitches `hole` (starting at position `anchorPos`) into `merged` at
    /// position `bridgePos`: `..., bridge, anchor, hole..., anchor,
    /// bridge, continues...`.
    private static func splice(merged: [Int], bridgePos: Int, hole: [Int], anchorPos: Int) -> [Int] {
        var insertion = Array(hole[anchorPos...] + hole[..<anchorPos])
        insertion.append(hole[anchorPos])
        insertion.append(merged[bridgePos])
        var result = merged
        result.insert(contentsOf: insertion, at: bridgePos + 1)
        return result
    }

    // MARK: - Ear clipping

    static func triangulate(_ indices: [Int], points: [CGPoint]) -> [(Int, Int, Int)] {
        guard indices.count >= 3 else { return [] }
        var remaining = indices
        if polygonSignedArea(remaining, points: points) < 0 {
            remaining.reverse()
        }

        var triangles: [(Int, Int, Int)] = []
        var guardCount = 0
        let maxIterations = remaining.count * remaining.count * 2 + 64

        outer: while remaining.count > 3 && guardCount < maxIterations {
            guardCount += 1
            let n = remaining.count

            // 1) Merge consecutive coincident points -- keeps arising
            //    whenever a bridge channel has been fully chewed away and
            //    its two sides collapse onto each other.
            for i in 0..<n {
                if samePoint(points[remaining[i]], points[remaining[(i + 1) % n]]) {
                    remaining.remove(at: (i + 1) % n)
                    continue outer
                }
            }

            // 2) Remove degenerate corners (spikes or collinear, area ~0)
            //    instead of letting them block an ear.
            for i in 0..<n {
                let iPrev = (i - 1 + n) % n
                let iNext = (i + 1) % n
                let a = points[remaining[iPrev]]
                let b = points[remaining[i]]
                let c = points[remaining[iNext]]
                if samePoint(a, c) || abs(orientation(a, b, c)) <= areaEps {
                    remaining.remove(at: i)
                    continue outer
                }
            }

            // 3) Look for a normal ear.
            for i in 0..<n {
                let iPrev = (i - 1 + n) % n
                let iNext = (i + 1) % n
                let a = points[remaining[iPrev]]
                let b = points[remaining[i]]
                let c = points[remaining[iNext]]
                guard orientation(a, b, c) > areaEps else { continue }
                var isEar = true
                for j in 0..<n {
                    if j == iPrev || j == i || j == iNext { continue }
                    let p = points[remaining[j]]
                    // Coincident duplicates (bridge points!) don't block an
                    // ear -- THAT was the core of the bug.
                    if samePoint(p, a) || samePoint(p, b) || samePoint(p, c) { continue }
                    if pointInTriangle(p, a, b, c) {
                        isEar = false
                        break
                    }
                }
                if isEar {
                    triangles.append((remaining[iPrev], remaining[i], remaining[iNext]))
                    remaining.remove(at: i)
                    continue outer
                }
            }

            // 4) No ear found (a numerical edge case): clip the most convex
            //    corner anyway, instead of silently discarding the rest of
            //    the polygon -- and with it whole pieces of the cap.
            var bestI = -1
            var bestOrient: CGFloat = 0
            for i in 0..<n {
                let iPrev = (i - 1 + n) % n
                let iNext = (i + 1) % n
                let o = orientation(points[remaining[iPrev]], points[remaining[i]], points[remaining[iNext]])
                if o > bestOrient {
                    bestOrient = o
                    bestI = i
                }
            }
            if bestI < 0 { break } // fully degenerate -- nothing left to gain
            let iPrev = (bestI - 1 + n) % n
            let iNext = (bestI + 1) % n
            triangles.append((remaining[iPrev], remaining[bestI], remaining[iNext]))
            remaining.remove(at: bestI)
        }

        if remaining.count == 3 {
            let a = points[remaining[0]]
            let b = points[remaining[1]]
            let c = points[remaining[2]]
            if abs(orientation(a, b, c)) > areaEps {
                triangles.append((remaining[0], remaining[1], remaining[2]))
            }
        }
        return triangles
    }

    // MARK: - Geometry helpers

    private static func distance2(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func onSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Bool {
        min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y)
    }

    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        if d1 == 0 && onSegment(p3, p4, p1) { return true }
        if d2 == 0 && onSegment(p3, p4, p2) { return true }
        if d3 == 0 && onSegment(p1, p2, p3) { return true }
        if d4 == 0 && onSegment(p1, p2, p4) { return true }
        return false
    }

    private static func polygonSignedArea(_ indices: [Int], points: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        let n = indices.count
        for i in 0..<n {
            let a = points[indices[i]]
            let b = points[indices[(i + 1) % n]]
            area += a.x * b.y - b.x * a.y
        }
        return area * 0.5
    }

    private static func pointInTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        let d1 = orientation(p, a, b)
        let d2 = orientation(p, b, c)
        let d3 = orientation(p, c, a)
        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
        return !(hasNeg && hasPos)
    }
}
