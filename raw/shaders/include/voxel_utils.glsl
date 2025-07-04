// the function in this header rely on the existance of some shared values
// layout(std140, set = 2, binding = 0) uniform CommonUBO {
//     uvec4 cascade_size; // x, y, z, _
//     uvec4 cascade_mask; // x, y, z, x*y*z
//     vec4 anchor; // x, y, z, _
//     uint n_cascades;
//     float min_voxel_size;
// };

uint indexToCascade(uint index) {
    return index / (cascade_size[0] * cascade_size[1] * cascade_size[2]);
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
    return cascade * cascade_size[0] * cascade_size[1] * cascade_size[2] +
           pos.x +
           pos.y * cascade_size[0] +
           pos.z * cascade_size[0] * cascade_size[1];
}

float voxelSize(uint cascade) {
    return min_voxel_size * float(1 << cascade);
}

uint cascadeAt(vec3 pos) {
    uvec3 cascades = uvec3(clamp(
        ceil(log2(abs(pos) / (0.5 * min_voxel_size * vec3(cascade_size.xyz)))),
        0,
        n_cascades + 1
    ));
    return max(cascades.x, max(cascades.y, cascades.z));
}
