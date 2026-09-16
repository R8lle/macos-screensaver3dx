// Matrix 3D X 1.0 (29) — Metal shader.
//
// A real .metal file instead of source compiled from a string at runtime:
// Xcode compiles it into the default library at build time, checks syntax/
// types immediately (errors show up in the editor, not only at runtime as
// a runtime exception), and provides syntax highlighting/autocompletion.

#include <metal_stdlib>
using namespace metal;

// MARK: - Matrix rain (2D, screen space)

struct GlyphVertexIn {
    float2 pos;
    float2 uv;
    float4 color;
};

struct GlyphVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

// Places one pre-tessellated glyph quad in screen space by converting its
// pixel position to normalized device coordinates.
vertex GlyphVertexOut glyph2d_vs(
    uint vid [[vertex_id]],
    constant GlyphVertexIn *verts [[buffer(0)]],
    constant float2 &screen [[buffer(1)]]
) {
    GlyphVertexIn v = verts[vid];
    float2 ndc;
    ndc.x = (v.pos.x / screen.x) * 2.0 - 1.0;
    ndc.y = (v.pos.y / screen.y) * 2.0 - 1.0;
    GlyphVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = v.uv;
    out.color = v.color;
    return out;
}

// Samples the glyph atlas and tints its brightness mask with the instance's
// rain color, shared by both 2D and 3D glyph rendering.
fragment float4 glyph_fs(
    GlyphVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(filter::nearest);
    float4 tex = atlas.sample(s, in.uv);
    // Atlas is black/white text on black -> use brightness as an alpha
    // mask for the actual (green) rain color.
    float mask = dot(tex.rgb, float3(0.299, 0.587, 0.114));
    float alpha = mask * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}

// MARK: - Volumetric 3D rain (camera-facing billboards in space)

struct Glyph3DInstanceData {
    float4 center;
    float4 right;
    float4 up;
    float4 color;
    float4 uv;
};

constant float2 kQuad[6] = {
    float2(-1, -1), float2(1, -1), float2(1, 1),
    float2(-1, -1), float2(1, 1), float2(-1, 1)
};
constant float2 kQuadUV[6] = {
    float2(0, 0), float2(1, 0), float2(1, 1),
    float2(0, 0), float2(1, 1), float2(0, 1)
};

// Expands one instance into a camera-facing quad using its right/up vectors,
// then projects it — the billboard trick for the volumetric 3D rain.
vertex GlyphVertexOut glyph3d_vs(
    uint iid [[instance_id]],
    uint vid [[vertex_id]],
    constant Glyph3DInstanceData *instances [[buffer(0)]],
    constant float4x4 &vp [[buffer(1)]]
) {
    Glyph3DInstanceData inst = instances[iid];
    float2 corner = kQuad[vid];
    float2 uvCorner = kQuadUV[vid];
    float3 world = inst.center.xyz + inst.right.xyz * corner.x + inst.up.xyz * corner.y;
    GlyphVertexOut out;
    out.position = vp * float4(world, 1.0);
    out.uv = mix(inst.uv.xy, inst.uv.zw, uvCorner);
    out.color = inst.color;
    return out;
}

// MARK: - Rotating 3D object (teapot)

struct SceneUniforms {
    float4x4 mvp;
    float4x4 vp;
    float4x4 model;
};

struct MeshVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct MeshVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 world;
};

// Transforms the mesh to world/clip space and carries the world-space
// normal forward for per-pixel lighting.
vertex MeshVertexOut mesh_vs(
    MeshVertexIn in [[stage_in]],
    constant SceneUniforms &scene [[buffer(2)]]
) {
    float4 world = scene.model * float4(in.position, 1.0);
    MeshVertexOut out;
    out.position = scene.vp * float4(world.xyz, 1.0);
    out.world = world.xyz;
    out.normal = normalize((scene.model * float4(in.normal, 0.0)).xyz);
    return out;
}

// Key+fill lighting: one main light plus a weaker counter light, so the
// side facing away from the main light doesn't fall back to a pure ambient
// value. Only for texture-less single-material models with no color of
// their own (the default teapot) -- models with their own material colors
// use mesh_col_fs.
fragment float4 mesh_fs(MeshVertexOut in [[stage_in]]) {
    float3 n = normalize(in.normal);
    float3 eye = float3(0.0, 0.05, 3.8);
    float3 v = normalize(eye - in.world);
    float3 keyLight = normalize(float3(0.35, 0.95, 0.45));
    float3 fillLight = normalize(float3(-0.45, 0.25, -0.6));
    float keyDiff = max(0.0, dot(n, keyLight));
    float fillDiff = max(0.0, dot(n, fillLight));
    float spec = pow(max(0.0, dot(reflect(-keyLight, n), v)), 48.0) * 0.35;
    float rim = pow(1.0 - max(0.0, dot(n, v)), 2.5) * 0.4;
    float3 base = float3(0.08, 0.52, 0.16);
    float lightAmount = 0.48 + 0.50 * keyDiff + 0.22 * fillDiff;
    float3 lit = base * lightAmount + float3(spec) + float3(0.04, 0.18, 0.06) * rim;
    return float4(lit, 1.0);
}

// MARK: - Environment reflection (for chrome + a light texture sheen)

float3 chrome_environment(float3 r) {
    float sky = smoothstep(-0.15, 0.8, r.y);
    float3 envLow = float3(0.18, 0.18, 0.19);
    float3 envHigh = float3(0.95, 0.96, 0.98);
    float3 env = mix(envLow, envHigh, sky);
    float streak = sin(r.x * 34.0 + r.z * 18.0) * sin(r.y * 52.0 + 1.7);
    streak = smoothstep(0.55, 1.0, streak) * smoothstep(0.0, 0.55, r.y);
    env += float3(0.42, 0.44, 0.47) * streak;
    return env;
}

// MARK: - Flat-colored submeshes (e.g. logo outer/inner faces)

struct MeshColorUniforms {
    float3 albedo;
    float pad;
};

fragment float4 mesh_col_fs(
    MeshVertexOut in [[stage_in]],
    constant MeshColorUniforms &color [[buffer(3)]]
) {
    float3 n = normalize(in.normal);
    float3 eye = float3(0.0, 0.05, 3.8);
    float3 v = normalize(eye - in.world);
    float3 keyLight = normalize(float3(0.35, 0.85, 0.55));
    float3 fillLight = normalize(float3(-0.45, 0.3, -0.55));
    float keyDiff = max(0.0, dot(n, keyLight));
    float fillDiff = max(0.0, dot(n, fillLight));
    float spec = pow(max(0.0, dot(reflect(-keyLight, n), v)), 32.0) * 0.15;
    // Lower ambient: 0.8 washed solid colors (Ralle/AWM blue) out to a pale light blue.
    float lightAmount = 0.48 + 0.50 * keyDiff + 0.22 * fillDiff;
    float3 lit = color.albedo * lightAmount + float3(spec);
    return float4(lit, 1.0);
}

// MARK: - Chrome submeshes (e.g. the R@lle logo's chrome plating)

fragment float4 mesh_chrome_fs(
    MeshVertexOut in [[stage_in]],
    constant MeshColorUniforms &color [[buffer(3)]]
) {
    float3 n = normalize(in.normal);
    float3 eye = float3(0.0, 0.05, 3.8);
    float3 v = normalize(eye - in.world);
    float3 r = reflect(-v, n);
    float3 env = chrome_environment(r);
    float3 light = normalize(float3(0.35, 0.85, 0.55));
    float3 h = normalize(light + v);
    float spec = pow(max(0.0, dot(n, h)), 260.0);
    float fresnel = pow(1.0 - max(0.0, dot(n, v)), 4.5);
    // Tinted by the material's base color: metallic reflection is colored
    // by the material color at a straight-on view, and only turns white
    // (Fresnel) toward a grazing angle -- a BLACK glossy material thus
    // stays dark with bright reflection edges instead of looking like
    // silver.
    float3 tint = color.albedo;
    float3 col = tint * 0.35 + env * mix(tint, float3(1.0), fresnel) * 0.75;
    col += float3(spec) * 1.2;
    col += float3(0.98, 0.99, 1.0) * fresnel * 0.45;
    return float4(col, 1.0);
}

// MARK: - Textured submeshes (e.g. the spaceship hull)

struct MeshTexturedVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

struct MeshTexturedVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 world;
    float2 uv;
};

// Same transform as mesh_vs, plus passing UVs through for the base color
// texture sample in mesh_tex_fs.
vertex MeshTexturedVertexOut mesh_tex_vs(
    MeshTexturedVertexIn in [[stage_in]],
    constant SceneUniforms &scene [[buffer(2)]]
) {
    float4 world = scene.model * float4(in.position, 1.0);
    MeshTexturedVertexOut out;
    out.position = scene.vp * float4(world.xyz, 1.0);
    out.world = world.xyz;
    out.normal = normalize((scene.model * float4(in.normal, 0.0)).xyz);
    // OBJ UVs: flip the V axis for Metal's image origin (the texture is
    // loaded without a flip, see TeapotMesh.swift) -- without this the
    // texture ends up upside down/mirrored.
    out.uv = float2(in.texcoord.x, 1.0 - in.texcoord.y);
    return out;
}

fragment float4 mesh_tex_fs(
    MeshTexturedVertexOut in [[stage_in]],
    texture2d<float> baseColor [[texture(1)]]
) {
    constexpr sampler s(filter::linear, address::repeat);
    float3 albedo = baseColor.sample(s, in.uv).rgb;
    float3 n = normalize(in.normal);
    float3 eye = float3(0.0, 0.05, 3.8);
    float3 v = normalize(eye - in.world);
    float3 keyLight = normalize(float3(0.35, 0.85, 0.55));
    float3 fillLight = normalize(float3(-0.45, 0.3, -0.55));
    float keyDiff = max(0.0, dot(n, keyLight));
    float fillDiff = max(0.0, dot(n, fillLight));
    float spec = pow(max(0.0, dot(reflect(-keyLight, n), v)), 48.0) * 0.28;
    float lightAmount = 0.50 + 0.48 * keyDiff + 0.22 * fillDiff;
    float3 lit = albedo * lightAmount + float3(spec);
    // Subtle paint sheen (environment reflection), stronger toward a
    // grazing angle (Fresnel) -- makes e.g. a spaceship hull look slightly
    // glossy overall, without blowing out the texture.
    float fresnel = pow(1.0 - max(0.0, dot(n, v)), 3.0);
    lit += chrome_environment(reflect(-v, n)) * (0.04 + 0.20 * fresnel);
    return float4(lit, 1.0);
}

// MARK: - PBR submeshes (imported GLB/USDZ models)
//
// Real Cook-Torrance/GGX metallic-roughness shading per pixel instead of a
// coarse chrome/non-chrome triangle split (see the comment in
// MeshAtlas.swift): each material keeps its metallic/roughness/emissive/
// normal values independently of its neighbors. Two analytic lights (the
// same key/fill direction as everywhere else in the renderer, so imported
// models match the rest of the scene) plus a simple ambient light
// (`chrome_environment` as a cheap IBL approximation for the specular part,
// a flat ambient term for the diffuse part).

constant float PBR_PI = 3.14159265359;

float pbr_distribution_ggx(float3 n, float3 h, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float nDotH = max(dot(n, h), 0.0);
    float nDotH2 = nDotH * nDotH;
    float denom = (nDotH2 * (a2 - 1.0) + 1.0);
    return a2 / max(PBR_PI * denom * denom, 1e-6);
}

float pbr_geometry_schlick_ggx(float nDotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return nDotV / max(nDotV * (1.0 - k) + k, 1e-6);
}

float pbr_geometry_smith(float3 n, float3 v, float3 l, float roughness) {
    float nDotV = max(dot(n, v), 0.0);
    float nDotL = max(dot(n, l), 0.0);
    return pbr_geometry_schlick_ggx(nDotV, roughness) * pbr_geometry_schlick_ggx(nDotL, roughness);
}

float3 pbr_fresnel_schlick(float cosTheta, float3 f0) {
    float m = clamp(1.0 - cosTheta, 0.0, 1.0);
    return f0 + (float3(1.0) - f0) * (m * m * m * m * m);
}

float3 pbr_fresnel_schlick_roughness(float cosTheta, float3 f0, float roughness) {
    float m = clamp(1.0 - cosTheta, 0.0, 1.0);
    return f0 + (max(float3(1.0 - roughness), f0) - f0) * (m * m * m * m * m);
}

struct MeshPBRVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
    float3 tangent [[attribute(3)]];
};

struct MeshPBRVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 tangent;
    float3 world;
    float2 uv;
};

// Same transform as mesh_vs, plus tangent (for normal mapping) and UVs.
vertex MeshPBRVertexOut mesh_pbr_vs(
    MeshPBRVertexIn in [[stage_in]],
    constant SceneUniforms &scene [[buffer(2)]]
) {
    float4 world = scene.model * float4(in.position, 1.0);
    MeshPBRVertexOut out;
    out.position = scene.vp * float4(world.xyz, 1.0);
    out.world = world.xyz;
    out.normal = normalize((scene.model * float4(in.normal, 0.0)).xyz);
    out.tangent = normalize((scene.model * float4(in.tangent, 0.0)).xyz);
    // OBJ UVs: flip the V axis for Metal's image origin (same as mesh_tex_vs).
    out.uv = float2(in.texcoord.x, 1.0 - in.texcoord.y);
    return out;
}

struct PBRFlags {
    int hasEmissive;
    int hasNormalMap;
};

fragment float4 mesh_pbr_fs(
    MeshPBRVertexOut in [[stage_in]],
    texture2d<float> baseColorTex [[texture(1)]],
    texture2d<float> ormTex [[texture(2)]],
    texture2d<float> emissiveTex [[texture(3)]],
    texture2d<float> normalTex [[texture(4)]],
    constant PBRFlags &flags [[buffer(3)]]
) {
    constexpr sampler s(filter::linear, address::repeat);
    float3 albedo = baseColorTex.sample(s, in.uv).rgb;
    float3 orm = ormTex.sample(s, in.uv).rgb;
    float ao = orm.r;
    float roughness = clamp(orm.g, 0.045, 1.0);
    float metallic = clamp(orm.b, 0.0, 1.0);

    float3 geomNormal = normalize(in.normal);
    float3 n = geomNormal;
    if (flags.hasNormalMap != 0) {
        float3 tangent = normalize(in.tangent - geomNormal * dot(geomNormal, in.tangent));
        float3 bitangent = cross(geomNormal, tangent);
        float3 sampled = normalTex.sample(s, in.uv).xyz * 2.0 - 1.0;
        n = normalize(tangent * sampled.x + bitangent * sampled.y + geomNormal * sampled.z);
    }

    float3 eye = float3(0.0, 0.05, 3.8);
    float3 v = normalize(eye - in.world);
    float3 f0 = mix(float3(0.04), albedo, metallic);

    float3 keyLight = normalize(float3(0.35, 0.85, 0.55));
    float3 fillLight = normalize(float3(-0.45, 0.3, -0.55));
    float3 keyRadiance = float3(3.1, 3.05, 2.95);
    float3 fillRadiance = float3(1.05, 1.1, 1.2);

    float3 lo = float3(0.0);
    {
        float3 l = keyLight;
        float3 h = normalize(v + l);
        float ndf = pbr_distribution_ggx(n, h, roughness);
        float g = pbr_geometry_smith(n, v, l, roughness);
        float3 f = pbr_fresnel_schlick(max(dot(h, v), 0.0), f0);
        float3 spec = (ndf * g * f) / max(4.0 * max(dot(n, v), 0.0) * max(dot(n, l), 0.0), 1e-4);
        float3 kd = (float3(1.0) - f) * (1.0 - metallic);
        float nDotL = max(dot(n, l), 0.0);
        lo += (kd * albedo / PBR_PI + spec) * keyRadiance * nDotL;
    }
    {
        float3 l = fillLight;
        float3 h = normalize(v + l);
        float ndf = pbr_distribution_ggx(n, h, roughness);
        float g = pbr_geometry_smith(n, v, l, roughness);
        float3 f = pbr_fresnel_schlick(max(dot(h, v), 0.0), f0);
        float3 spec = (ndf * g * f) / max(4.0 * max(dot(n, v), 0.0) * max(dot(n, l), 0.0), 1e-4);
        float3 kd = (float3(1.0) - f) * (1.0 - metallic);
        float nDotL = max(dot(n, l), 0.0);
        lo += (kd * albedo / PBR_PI + spec) * fillRadiance * nDotL;
    }

    // Ambient light: a cheap IBL approximation instead of real environment-
    // map convolution -- good enough for a rotating preview object, so it
    // doesn't look completely unlit/black wherever the two analytic lights
    // aren't enough.
    float3 fEnv = pbr_fresnel_schlick_roughness(max(dot(n, v), 0.0), f0, roughness);
    float3 kdEnv = (float3(1.0) - fEnv) * (1.0 - metallic);
    float3 ambientDiffuse = kdEnv * albedo * 0.20;
    float3 envColor = chrome_environment(reflect(-v, n));
    // chrome_environment produces a SHARP, unblurred reflection -- real
    // image-based lighting would blur it proportionally to roughness
    // (irradiance convolution), which is missing here. Without strong
    // attenuation, even moderately rough, essentially near-matte surfaces
    // (e.g. photo-PBR planets with roughness ~0.4-0.7) look noticeably
    // glossier than in a real IBL renderer -- a quadratic instead of
    // linear falloff keeps low roughness (genuinely glossy materials like
    // a spaceship hull) unchanged and glossy, while pushing the effect down
    // much more strongly at medium/high roughness.
    float roughnessFalloff = (1.0 - roughness) * (1.0 - roughness);
    float3 ambientSpecular = envColor * fEnv * roughnessFalloff;
    float3 ambient = (ambientDiffuse + ambientSpecular) * ao;

    float3 emissive = flags.hasEmissive != 0 ? emissiveTex.sample(s, in.uv).rgb : float3(0.0);
    float3 color = ambient + lo + emissive;
    return float4(color, 1.0);
}

// MARK: - Batch raycasting (physics glyph collision, compute)
//
// Brute-force ray/triangle test per ray, parallelized over the queries
// (not over the triangles) -- fast enough for real time at the object
// sizes used here (a few thousand triangles, up to 2048 rays/frame),
// with no spatial acceleration structure on the GPU side at all.

struct RaycastSceneParams {
    uint triCount;
    uint queryCount;
    float2 pad;
    float4 bmin;
    float4 bmax;
};

struct RayQueryGPU {
    float4 origin;
    float4 direction;
};

struct RayHitGPU {
    float4 position;
    float4 normal;
    float distance;
    float valid;
};

// Möller–Trumbore ray/triangle intersection; writes the hit distance to
// tOut and returns false for a miss or a backfacing/grazing triangle.
inline bool intersect_triangle_r(float3 orig, float3 dir, float3 v0, float3 v1, float3 v2, thread float &tOut) {
    const float EPS = 1e-7;
    float3 edge1 = v1 - v0;
    float3 edge2 = v2 - v0;
    float3 pvec = cross(dir, edge2);
    float det = dot(edge1, pvec);
    if (abs(det) < EPS) return false;
    float invDet = 1.0 / det;
    float3 tvec = orig - v0;
    float u = dot(tvec, pvec) * invDet;
    if (u < 0.0 || u > 1.0) return false;
    float3 qvec = cross(tvec, edge1);
    float v = dot(dir, qvec) * invDet;
    if (v < 0.0 || u + v > 1.0) return false;
    float t = dot(edge2, qvec) * invDet;
    if (t < EPS) return false;
    tOut = t;
    return true;
}

// Slab-method ray/AABB test, used as a cheap early-out before the per-
// triangle loop in raycast_kernel.
inline bool intersect_aabb_r(float3 orig, float3 dir, float3 bmin, float3 bmax, thread float &tEnter, thread float &tExit) {
    tEnter = 0.0;
    tExit = 1e30;
    for (uint i = 0; i < 3; ++i) {
        float o = orig[i];
        float d = dir[i];
        float mn = bmin[i];
        float mx = bmax[i];
        if (abs(d) < 1e-8) {
            if (o < mn || o > mx) return false;
            continue;
        }
        float inv = 1.0 / d;
        float t1 = (mn - o) * inv;
        float t2 = (mx - o) * inv;
        if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
        tEnter = max(tEnter, t1);
        tExit = min(tExit, t2);
        if (tExit < tEnter) return false;
    }
    return tExit >= 0.0;
}

// One thread per query ray: rejects rays that miss the object's bounding
// box outright, otherwise finds the nearest intersecting triangle.
kernel void raycast_kernel(
    device const RaycastSceneParams *scene [[buffer(0)]],
    device const float *triVertices [[buffer(1)]],
    device const RayQueryGPU *queries [[buffer(2)]],
    device RayHitGPU *hits [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint queryCount = scene->queryCount;
    if (gid >= queryCount) return;

    float3 origin = queries[gid].origin.xyz;
    float3 direction = normalize(queries[gid].direction.xyz);

    float3 bmin = scene->bmin.xyz;
    float3 bmax = scene->bmax.xyz;
    float tEnter = 0.0, tExit = 0.0;
    if (!intersect_aabb_r(origin, direction, bmin, bmax, tEnter, tExit)) {
        hits[gid].valid = 0.0;
        return;
    }

    uint triCount = scene->triCount;
    float bestT = 1e30;
    bool found = false;
    float3 bestPos = float3(0.0);
    float3 bestN = float3(0.0, 1.0, 0.0);

    for (uint t = 0; t < triCount; ++t) {
        uint base = t * 9;
        float3 a = float3(triVertices[base + 0], triVertices[base + 1], triVertices[base + 2]);
        float3 b = float3(triVertices[base + 3], triVertices[base + 4], triVertices[base + 5]);
        float3 c = float3(triVertices[base + 6], triVertices[base + 7], triVertices[base + 8]);
        float tHit = 0.0;
        if (intersect_triangle_r(origin, direction, a, b, c, tHit) && tHit < bestT) {
            bestT = tHit;
            bestPos = origin + direction * tHit;
            bestN = normalize(cross(b - a, c - a));
            found = true;
        }
    }

    if (!found) {
        hits[gid].valid = 0.0;
        return;
    }
    hits[gid].position = float4(bestPos, 1.0);
    hits[gid].normal = float4(bestN, 0.0);
    hits[gid].distance = bestT;
    hits[gid].valid = 1.0;
}
