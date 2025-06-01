#version 460

layout(location = 0) in vec3 ray_origin;
layout(location = 1) in vec3 ray_dir;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler3D cascades;

vec4 voxelFetch(ivec3 voxel_pos, int cascade) {
    return texelFetch(cascades, ivec3(voxel_pos.x + 64 * cascade, voxel_pos.yz), 0);
}

int cascadeAt(vec3 pos) {
    int cascade = 0;
    float bound = 4.0;
    float minimum = min(min(pos.r, pos.g), pos.b);
    float maximum = max(max(pos.r, pos.g), pos.b);
    while (minimum < -bound || bound < maximum) {
        bound *= 2.0;
        ++cascade;
    }
    return cascade;
}

float voxelSize(int cascade) {
    return 0.125 * float(1 << cascade);
}

vec4 voxelAt(vec3 pos) {
    int cascade = cascadeAt(pos);
    float voxel_size = voxelSize(cascade);
    return voxelFetch(ivec3(floor(pos / voxel_size)) + 32, cascade);
}

void main() {
    out_color = vec4(ray_dir, 1.0);

    vec3 pos = ray_origin;
    
    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);

    for (int i = 0; i < 512; ++i) {
        pos += 0.5 * voxelSize(cascadeAt(pos)) * ray_dir;
        vec4 voxel_color = voxelAt(pos);
        float a = voxel_color.a;
        // if (a > 0) a = 1.0;
        // TODO add debug mode showing transparency for higher cascades in central regions
        // acc.rgb += voxel_color.rgb * voxel_color.a * (1.0 - acc.a);
        // acc.a += voxel_color.a * (1.0 - acc.a);
        acc.rgb += voxel_color.rgb * a * (1.0 - acc.a);
        acc.a += a * (1.0 - acc.a);

        if (acc.a > 0.99) break;
    }

    out_color = (1.0 - acc.a) * out_color + acc.a * acc;
}
