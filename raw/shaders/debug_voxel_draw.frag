#version 460

layout(location = 0) in vec3 ray_origin;
layout(location = 1) in vec3 ray_dir;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform usampler3D cascades;

vec4 unpackRGBA(uint packed) {
    return vec4(
        float((packed >> 24) & 0xFFu) / 255.0,
        float((packed >> 16) & 0xFFu) / 255.0,
        float((packed >> 8) & 0xFFu) / 255.0,
        float((packed >> 0) & 0xFFu) / 255.0
    );
}

uint voxelFetch(ivec3 voxel_pos, int cascade) {
    return texelFetch(cascades, ivec3(voxel_pos.x + 64 * cascade, voxel_pos.yz), 0).r;
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

void main() {
    out_color = vec4(ray_dir, 1.0);

    // int cascade = cascadeAt(ray_origin);
    // float step_size = voxelSize(cascade);
    float step_size = 0.125;
    ivec3 voxel_pos = ivec3(floor(ray_origin / step_size));
    ivec3 step = ivec3(sign(ray_dir));
    vec3 dt = abs(step_size / ray_dir);
    
    vec3 t_max;
    if (ray_dir.x < 0.0) {
        t_max.x = ( (float(voxel_pos.x) * step_size) - ray_origin.x ) / ray_dir.x;
    } else if (ray_dir.x > 0.0) {
        t_max.x = ( (float(voxel_pos.x + 1) * step_size) - ray_origin.x ) / ray_dir.x;
    } else {
        t_max.x = 1e38;
    }
    if (ray_dir.y < 0.0) {
        t_max.y = ( (float(voxel_pos.y) * step_size) - ray_origin.y ) / ray_dir.y;
    } else if (ray_dir.y > 0.0) {
        t_max.y = ( (float(voxel_pos.y + 1) * step_size) - ray_origin.y ) / ray_dir.y;
    } else {
        t_max.y = 1e38;
    }
    if (ray_dir.z < 0.0) {
        t_max.z = ( (float(voxel_pos.z) * step_size) - ray_origin.z ) / ray_dir.z;
    } else if (ray_dir.z > 0.0) {
        t_max.z = ( (float(voxel_pos.z + 1) * step_size) - ray_origin.z ) / ray_dir.z;
    } else {
        t_max.z = 1e38;
    }

    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);

    for (int i = 0; i < 1024; ++i) {
        if (t_max.x < t_max.y) {
            if (t_max.x < t_max.z) {
                t_max.x += dt.x;
                voxel_pos.x += step.x;
            } else {
                t_max.z += dt.z;
                voxel_pos.z += step.z;
            }
        } else {
            if (t_max.y < t_max.z) {
                t_max.y += dt.y;
                voxel_pos.y += step.y;
            } else {
                t_max.z += dt.z;
                voxel_pos.z += step.z;
            }
        }

        // if (voxel_pos.x < -32 || voxel_pos.x >= 32 ||
        //     voxel_pos.y < -32 || voxel_pos.y >= 32 ||
        //     voxel_pos.z < -32 || voxel_pos.z >= 32) {
        //     break;
        // }

        // vec4 voxel_color = unpackRGBA(texelFetch(cascades, voxel_pos + 32, 0).r);
        uint packed = voxelFetch(voxel_pos + 32, 0);
        vec4 voxel_color = unpackRGBA(packed);
        float a = ((packed & 0xFFu) == 0) ? 0.0 : 1.0;
        // acc.rgb += voxel_color.rgb * voxel_color.a * (1.0 - acc.a);
        // acc.a += voxel_color.a * (1.0 - acc.a);
        acc.rgb += voxel_color.rgb * a * (1.0 - acc.a);
        acc.a += a * (1.0 - acc.a);

        if (acc.a > 0.99) break;
    }

    out_color = (1.0 - acc.a) * out_color + acc.a * acc;
}
