#version 460

layout(location = 0) in vec3 ray_origin;
layout(location = 1) in vec3 ray_dir;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler3D cascade_coverage;
layout(set = 2, binding = 1) uniform sampler3D cascade_diffuse;
layout(set = 2, binding = 2) uniform sampler3D cascade_emissive;
layout(set = 2, binding = 3) uniform sampler3D cascade_normal;
layout(set = 2, binding = 4) uniform sampler3D cascade_radiance;

layout(set = 3, binding = 0) uniform DebugData {
    uint mode;
} debug_data;

vec4 voxelFetch(ivec3 voxel_pos, int cascade) {
    vec4 c;
    switch (debug_data.mode) {
    case 0:
        c = texelFetch(cascade_coverage, ivec3(voxel_pos.x + 64 * cascade, voxel_pos.yz), 0);
        c = vec4(1.0, 1.0, 1.0, c.r);
        break;        
    case 1:
        return texelFetch(cascade_diffuse, ivec3(voxel_pos.x + 64 * cascade, voxel_pos.yz), 0);
        break;        
    case 2:
        // TODO tonemap
        return texelFetch(cascade_emissive, ivec3(voxel_pos.x + 64 * cascade, voxel_pos.yz), 0);
        break;        
    case 3:
        c = texelFetch(cascade_normal, ivec3(voxel_pos.x + 64 * cascade, voxel_pos.yz), 0);
        c = vec4(0.5 * (c.rgb + 1.0), c.a);
        break;        
    case 4:
        // TODO tonemap
        return texelFetch(cascade_radiance, ivec3(voxel_pos.x + 64 * cascade, voxel_pos.yz), 0);
        break;        
    }
    return c;
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

    for (int i = 0; i < 1024; ++i) {
        pos += 0.5 * voxelSize(cascadeAt(pos)) * ray_dir;
        vec4 voxel_color = voxelAt(pos);
        float a = voxel_color.a;
        acc.rgb += voxel_color.rgb * a * (1.0 - acc.a);
        acc.a += a * (1.0 - acc.a);

        if (acc.a > 0.99) break;
    }

    out_color = (1.0 - acc.a) * out_color + acc.a * acc;
}
