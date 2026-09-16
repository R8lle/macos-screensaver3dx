import simd

/// Camera, projection, and object rotation.
///
/// Matrix convention: column-major, `M * v` with `v` as a column vector --
/// `simd_float4x4` has exactly this convention built in.
enum Scene {
    /// Camera position; the origin lies on the object's viewing axis (Z).
    static let cameraEye = SIMD3<Float>(0.0, 0.05, 3.8)
    static let fovY: Float = 48.0 * .pi / 180.0
    static let nearZ: Float = 0.15
    static let farZ: Float = 40.0

    /// Rotation speed per axis in radians/second.
    static let rotateSpeedX: Float = 0.18
    static let rotateSpeedY: Float = 0.35
    static let rotateSpeedZ: Float = 0.22

    /// Fixed object depth when the 3D object is visible (variant "with
    /// object") -- no flying in, stable sitting/rotating in the local
    /// frame.
    static let objectZWithObject: Float = 0.72

    /// Reference depth for constant 3D glyph size (independent of
    /// objectZ).
    static let glyphSizeRefZ: Float = 2.25

    static func cameraTarget(objectZ: Float) -> SIMD3<Float> {
        SIMD3<Float>(0, 0, objectZ * 0.5)
    }

    /// Converts a pixel size (screen space) to world-coordinate units at a
    /// fixed reference depth -- for a constant perceived character size
    /// independent of object depth.
    static func worldUnitsForPixels(_ pixels: Float, screenHeight: Float, worldZ: Float = glyphSizeRefZ) -> Float {
        let depth = max(0.5, cameraEye.z - worldZ)
        return pixels * 2.0 * depth * tan(fovY * 0.5) / max(1, screenHeight)
    }

    /// Camera-aligned axes for billboard orientation of the volumetric 3D
    /// rain (each character is a quad facing the camera).
    static func cameraBillboardAxes(objectZ: Float) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let target = cameraTarget(objectZ: objectZ)
        let forward = normalize(target - cameraEye)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(worldUp, forward))
        let up = normalize(cross(forward, right))
        return (right, up)
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1.0 / tan(fovY * 0.5)
        let nf = 1.0 / (near - far)
        return simd_float4x4(
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, (far + near) * nf, -1),
            SIMD4<Float>(0, 0, 2 * far * near * nf, 0)
        )
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return simd_float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        )
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }

    static func scaleUniform(_ s: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(s, 0, 0, 0),
            SIMD4<Float>(0, s, 0, 0),
            SIMD4<Float>(0, 0, s, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    /// Rotation around all three axes at time `elapsed` (radians). Each
    /// axis can be individually disabled (angle stays 0), matching the
    /// rotation checkboxes in the options dialog.
    static func objectRotation(elapsed: Float, spinX: Bool, spinY: Bool, spinZ: Bool) -> SIMD3<Float> {
        SIMD3<Float>(
            spinX ? elapsed * rotateSpeedX : 0,
            spinY ? elapsed * rotateSpeedY : 0,
            spinZ ? elapsed * rotateSpeedZ : 0
        )
    }

    static func rotationMatrix(_ r: SIMD3<Float>) -> simd_float4x4 {
        rotationZ(r.z) * rotationY(r.y) * rotationX(r.x)
    }

    /// Combined rotation `R_tilt * R_spin` (both as Rz*Ry*Rx chains). The
    /// fixed tilt is on the OUTSIDE: the object rotates (animated) around
    /// its own axes and is then tilted as a whole -- the rotation axes tilt
    /// along with the object as a result (globe-like behavior).
    static func rotationMatrix(spin: SIMD3<Float>, tiltDegrees: SIMD3<Float>) -> simd_float4x4 {
        let spinMatrix = rotationMatrix(spin)
        if tiltDegrees == .zero { return spinMatrix }
        let tilt = tiltDegrees * (.pi / 180)
        let tiltMatrix = rotationZ(tilt.z) * rotationY(tilt.y) * rotationX(tilt.x)
        return tiltMatrix * spinMatrix
    }

    /// Model matrix: first center on its own center, scale, rotate (+tilt),
    /// then shift to the fixed object depth.
    static func objectModelMatrix(center: SIMD3<Float>, scale: Float, objectZ: Float, spin: SIMD3<Float>, tiltDegrees: SIMD3<Float>) -> simd_float4x4 {
        let rot = rotationMatrix(spin: spin, tiltDegrees: tiltDegrees)
        return translation(SIMD3<Float>(0, 0, objectZ)) * rot * scaleUniform(scale) * translation(-center)
    }

    static func rotationMatrix3x3(spin: SIMD3<Float>, tiltDegrees: SIMD3<Float>) -> simd_float3x3 {
        let m = rotationMatrix(spin: spin, tiltDegrees: tiltDegrees)
        return simd_float3x3([
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z),
        ])
    }

    /// World coordinates -> local mesh space (inverse of the object
    /// rotation, WITHOUT object depth -- the caller handles that before/
    /// after via translation). For raycast origin/direction.
    static func worldToLocal(_ v: SIMD3<Float>, rotation3x3: simd_float3x3) -> SIMD3<Float> {
        rotation3x3.transpose * v
    }

    /// Local mesh space -> world coordinates (without object depth, see above).
    static func localToWorld(_ v: SIMD3<Float>, rotation3x3: simd_float3x3) -> SIMD3<Float> {
        rotation3x3 * v
    }

    /// Camera ray directions (world space) for a list of screen points
    /// (AppKit convention: origin at bottom left).
    static func worldRayDirection(screenX: Float, screenY: Float, width: Float, height: Float, objectZ: Float) -> SIMD3<Float> {
        let aspect = width / max(1, height)
        let ndcX = (screenX / width) * 2 - 1
        let ndcY = (screenY / height) * 2 - 1
        let eye = cameraEye
        let target = cameraTarget(objectZ: objectZ)
        let forward = normalize(target - eye)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(forward, worldUp))
        let up = cross(right, forward)
        let tanHalf = tan(fovY * 0.5)
        let dir = forward + right * (ndcX * tanHalf * aspect) + up * (ndcY * tanHalf)
        return normalize(dir)
    }

    static func viewProjection(width: Float, height: Float, objectZ: Float) -> simd_float4x4 {
        let aspect = width / max(1, height)
        let proj = perspective(fovY: fovY, aspect: aspect, near: nearZ, far: farZ)
        let view = lookAt(eye: cameraEye, center: cameraTarget(objectZ: objectZ), up: SIMD3<Float>(0, 1, 0))
        return proj * view
    }

    /// World position -> screen point (AppKit convention, origin at bottom
    /// left), or nil if behind the camera / outside the depth range.
    static func projectWorldToScreen(_ p: SIMD3<Float>, width: Float, height: Float, objectZ: Float) -> (Float, Float)? {
        let vp = viewProjection(width: width, height: height, objectZ: objectZ)
        let clip = vp * SIMD4<Float>(p.x, p.y, p.z, 1)
        guard clip.w > 1e-5 else { return nil }
        let ndcX = clip.x / clip.w
        let ndcY = clip.y / clip.w
        let ndcZ = clip.z / clip.w
        guard ndcZ >= -1 && ndcZ <= 1 else { return nil }
        return ((ndcX + 1) * 0.5 * width, (ndcY + 1) * 0.5 * height)
    }
}
