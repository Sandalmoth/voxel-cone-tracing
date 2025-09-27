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

uint indexFromCascadePosBinning(uint cascade, ivec3 pos) {
    pos += ivec3(cascade_size.xyz / 8);
    return cascade * cascade_size[3] / 64 +
           pos.x +
           pos.y * cascade_size[0] / 4 +
           pos.z * cascade_size[0] * cascade_size[1] / 4;
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

uint packDiffuse(vec3 c) {
    // this could be converted to a lookup table, it's only 1573 possible colors I think
    float r_pos = max(0, 2.0 * (c.r - 0.5));
    float r_neg = max(0, 2.0 * (0.5 - c.r));
    float g_pos = max(0, 2.0 * (c.g - 0.5));
    float g_neg = max(0, 2.0 * (0.5 - c.g));
    float b_pos = max(0, 2.0 * (c.b - 0.5));
    float b_neg = max(0, 2.0 * (0.5 - c.b));

    uint r_pos_bits = quantizeToBitmask(r_pos, 5);
    uint r_neg_bits = quantizeToBitmask(r_neg, 5);
    uint g_pos_bits = quantizeToBitmask(g_pos, 6);
    uint g_neg_bits = quantizeToBitmask(g_neg, 6);
    uint b_pos_bits = quantizeToBitmask(b_pos, 5);
    uint b_neg_bits = quantizeToBitmask(b_neg, 5);

    return (r_pos_bits << 27) |
           (r_neg_bits << 22) |
           (g_pos_bits << 16) |
           (g_neg_bits << 10) |
           (b_pos_bits <<  5) |
           (b_neg_bits      );
}

float dequantizeFromBitmask(uint bits, int nbits) {
    int q = bitCount(bits);
    return float(q) / float(nbits);
}

vec3 unpackDiffuse(uint packed) {
    uint r_pos_bits = (packed >> 27) & 0x1Fu;
    uint r_neg_bits = (packed >> 22) & 0x1Fu;
    uint g_pos_bits = (packed >> 16) & 0x3Fu;
    uint g_neg_bits = (packed >> 10) & 0x3Fu;
    uint b_pos_bits = (packed >>  5) & 0x1Fu;
    uint b_neg_bits =  packed        & 0x1Fu;

    float r_pos = dequantizeFromBitmask(r_pos_bits, 5);
    float r_neg = dequantizeFromBitmask(r_neg_bits, 5);
    float g_pos = dequantizeFromBitmask(g_pos_bits, 6);
    float g_neg = dequantizeFromBitmask(g_neg_bits, 6);
    float b_pos = dequantizeFromBitmask(b_pos_bits, 5);
    float b_neg = dequantizeFromBitmask(b_neg_bits, 5);

    float r = 0.5 + 0.5 * (r_pos - r_neg);
    float g = 0.5 + 0.5 * (g_pos - g_neg);
    float b = 0.5 + 0.5 * (b_pos - b_neg);

    return vec3(r, g, b);
}

