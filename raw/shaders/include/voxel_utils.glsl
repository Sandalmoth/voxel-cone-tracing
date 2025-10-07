// the function in this header rely on the existance of some shared values
// layout(std140, set = 2, binding = 0) uniform CommonUBO {
//     uvec4 cascade_size; // x, y, z, x*y*z
//     uvec4 cascade_mask; // x, y, z, x*y*z
//     uint n_cascades;
//     float min_voxel_size;
//     vec4 anchors[MAX_CASCADES]; // x, y, z, _
// };

uint indexToCascade(uint index) {
    return index / cascade_size[3];
}

ivec3 indexToPos(uint index) {
    return ivec3(
         index & cascade_mask[0],
        (index / cascade_size[0]) & cascade_mask[1],
        (index / (cascade_size[0] * cascade_size[1])) & cascade_mask[2]
    ) - ivec3(cascade_size.xyz / 2);
}

uint indexFromCascadePos(uint cascade, ivec3 pos) {
    pos += ivec3(cascade_size.xyz / 2);
    return cascade * cascade_size[3] +
           pos.x +
           pos.y * cascade_size[0] +
           pos.z * cascade_size[0] * cascade_size[1];
}

float voxelSize(uint cascade) {
    return min_voxel_size * float(1 << cascade);
}

uint cascadeAt(vec3 pos) {
    uvec3 cascades = uvec3(clamp(
        ceil(log2(abs(pos - anchors[0].xyz) / (0.5 * min_voxel_size * vec3(cascade_size.xyz - 6)))),
        0,
        n_cascades
    ));
    return max(cascades.x, max(cascades.y, cascades.z));
}

float cascadeAtFractional(vec3 pos) {
    vec3 cascades = clamp(
        log2(abs(pos - anchors[0].xyz) / (0.5 * min_voxel_size * vec3(cascade_size.xyz - 6))) + 1,
        0,
        n_cascades
    );
    return max(cascades.x, max(cascades.y, cascades.z));
}

uint quantizeToBitmask(float v, int bits) {
    uint q = uint(v * float(bits) + 0.5);
    return (1u << q) - 1u;
}

uint packDiffuseOpacity(vec4 c) {
    float r_pos = max(0, 2.0 * (c.r - 0.5));
    float r_neg = max(0, 2.0 * (0.5 - c.r));
    float g_pos = max(0, 2.0 * (c.g - 0.5));
    float g_neg = max(0, 2.0 * (0.5 - c.g));
    float b_pos = max(0, 2.0 * (c.b - 0.5));
    float b_neg = max(0, 2.0 * (0.5 - c.b));

    uint r_pos_bits = quantizeToBitmask(r_pos, 5);
    uint r_neg_bits = quantizeToBitmask(r_neg, 5);
    uint g_pos_bits = quantizeToBitmask(g_pos, 5);
    uint g_neg_bits = quantizeToBitmask(g_neg, 5);
    uint b_pos_bits = quantizeToBitmask(b_pos, 5);
    uint b_neg_bits = quantizeToBitmask(b_neg, 5);
    uint alpha_bits = quantizeToBitmask(c.a, 2);

    return (r_pos_bits << 27u) |
           (r_neg_bits << 22u) |
           (g_pos_bits << 17u) |
           (g_neg_bits << 12u) |
           (b_pos_bits <<  7u) |
           (b_neg_bits <<  2u) |
           (alpha_bits       );
}

float dequantizeFromBitmask(uint bits, int nbits) {
    int q = bitCount(bits);
    return float(q) / float(nbits);
}

vec4 unpackDiffuseOpacity(uint packed) {
    uint r_pos_bits = (packed >> 27u) & 0x1Fu;
    uint r_neg_bits = (packed >> 22u) & 0x1Fu;
    uint g_pos_bits = (packed >> 17u) & 0x1Fu;
    uint g_neg_bits = (packed >> 12u) & 0x1Fu;
    uint b_pos_bits = (packed >>  7u) & 0x1Fu;
    uint b_neg_bits = (packed >>  2u) & 0x1Fu;
    uint alpha_bits =  packed         & 0x3u;

    float r_pos = dequantizeFromBitmask(r_pos_bits, 5);
    float r_neg = dequantizeFromBitmask(r_neg_bits, 5);
    float g_pos = dequantizeFromBitmask(g_pos_bits, 5);
    float g_neg = dequantizeFromBitmask(g_neg_bits, 5);
    float b_pos = dequantizeFromBitmask(b_pos_bits, 5);
    float b_neg = dequantizeFromBitmask(b_neg_bits, 5);
    float a = dequantizeFromBitmask(alpha_bits, 2);

    float r = 0.5 + 0.5 * (r_pos - r_neg);
    float g = 0.5 + 0.5 * (g_pos - g_neg);
    float b = 0.5 + 0.5 * (b_pos - b_neg);

    return vec4(r, g, b, a);
}

struct IntersectionInfo {
    vec3 n;
    vec3 c;
    vec2 ne0xy;
    vec2 ne1xy;
    vec2 ne2xy;
    vec2 ne0yz;
    vec2 ne1yz;
    vec2 ne2yz;
    vec2 ne0zx;
    vec2 ne1zx;
    vec2 ne2zx;
    float de0xy;
    float de1xy;
    float de2xy;
    float de0yz;
    float de1yz;
    float de2yz;
    float de0zx;
    float de1zx;
    float de2zx;
};

bool intersectVoxelTriangle(
    vec3 low, float ext, vec3 p0, vec3 p1, vec3 p2,
    IntersectionInfo info
    // vec3 n, vec3 c,
    // vec2 ne0xy, vec2 ne1xy, vec2 ne2xy, float de0xy, float de1xy, float de2xy,
    // vec2 ne0yz, vec2 ne1yz, vec2 ne2yz, float de0yz, float de1yz, float de2yz,
    // vec2 ne0zx, vec2 ne1zx, vec2 ne2zx, float de0zx, float de1zx, float de2zx
) {
    // https://omnigoat.github.io/2015/03/09/box-triangle-intersection/

    {
        vec3 mins = min(p0, min(p1, p2));
        vec3 maxs = max(p0, max(p1, p2)); 
        if ((mins.x > (low + ext).x) || (maxs.x < low.x) ||
            (mins.y > (low + ext).y) || (maxs.y < low.y) ||
            (mins.z > (low + ext).z) || (maxs.z < low.z)) return false;
    }
    // {
    //     float d1 = dot(info.n, low + info.c - p0);
    //     float d2 = dot(info.n, low + ext - info.c - p0);
    //     if (d1 * d2 > 0.0) return false;
    // }
    {
        float d1 = dot(info.n, info.c - p0);
        float d2 = dot(info.n, ext - info.c - p0);
        if ((dot(info.n, low) + d1) * (dot(info.n, low) + d2) > 0.0) return false;
    }

    if (dot(info.ne0xy, low.xy) + info.de0xy < 0.0) return false;
    if (dot(info.ne1xy, low.xy) + info.de1xy < 0.0) return false;
    if (dot(info.ne2xy, low.xy) + info.de2xy < 0.0) return false;
    if (dot(info.ne0yz, low.yz) + info.de0yz < 0.0) return false;
    if (dot(info.ne1yz, low.yz) + info.de1yz < 0.0) return false;
    if (dot(info.ne2yz, low.yz) + info.de2yz < 0.0) return false;
    if (dot(info.ne0zx, low.zx) + info.de0zx < 0.0) return false;
    if (dot(info.ne1zx, low.zx) + info.de1zx < 0.0) return false;
    if (dot(info.ne2zx, low.zx) + info.de2zx < 0.0) return false;

    return true;
}
