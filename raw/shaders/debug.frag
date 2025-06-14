#version 460

#define MIN_VOXEL_SIZE 0.244140625

layout(location = 0) in vec3 v_ray_origin;
layout(location = 1) in vec3 v_ray_dir;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler3D u_opacity_cascades;

uint cascadeAt(vec3 pos) {
    vec3 a = abs(pos);
    float maximum = max(max(a.x, a.y), a.z);
    return uint(clamp(ceil(log2(maximum / (MIN_VOXEL_SIZE * 32))), 0, 8));
}

float voxelSize(uint cascade) {
    return MIN_VOXEL_SIZE * float(1 << cascade);
}

float voxelAt(vec3 pos) {
    uint cascade = cascadeAt(pos);
    if (cascade == 8) return 0.0;
    float voxel_size = voxelSize(cascade);
    ivec3 voxel_pos = ivec3(floor(pos / voxel_size)) + 33;
    return texelFetch(u_opacity_cascades, ivec3(voxel_pos.x + 66 * cascade, voxel_pos.yz), 0).r;
}

void main() {
    o_color = vec4(0.5 * v_ray_dir + 0.5, 1.0);

    vec3 pos = v_ray_origin;
    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);
    float d = 0.0;
    
    for (int i = 0; i < 1024; ++i) {
        float step = 0.25 * voxelSize(cascadeAt(pos));
        d += step;
        pos += step * v_ray_dir;
        float occlusion = voxelAt(pos);
        vec4 voxel_color = vec4(1.0, 1.0, 1.0, occlusion);
        voxel_color = vec4(clamp(voxel_color.rgb * exp(-d*0.02), 0.01, 10.0), voxel_color.a);
        float a = voxel_color.a;
        acc.rgb += voxel_color.rgb * a * (1.0 - acc.a);
        acc.a += a * (1.0 - acc.a);

        if (acc.a > 0.99) break;
    }

    o_color = (1.0 - acc.a) * o_color + acc.a * acc;
}
