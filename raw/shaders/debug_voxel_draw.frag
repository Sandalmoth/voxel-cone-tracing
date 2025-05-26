#version 460

layout(location = 0) in vec3 ray_origin;
layout(location = 1) in vec3 ray_dir;

layout(location = 0) out vec4 out_color;

// layout(r32i, set = 2, binding = 0) uniform uimage3D cascade0;
// layout(r32i, set = 2, binding = 1) uniform uimage3D cascade1;
// layout(r32i, set = 2, binding = 2) uniform uimage3D cascade2;
// layout(r32i, set = 2, binding = 3) uniform uimage3D cascade3;

layout(r32ui, set = 2, binding = 0) uniform readonly uimage3D cascades[4];

vec4 unpackRGBA(uint packed) {
    return vec4(
        float((packed >> 0) & 0xFFu) / 255.0,
        float((packed >> 8) & 0xFFu) / 255.0,
        float((packed >> 16) & 0xFFu) / 255.0,
        float((packed >> 24) & 0xFFu) / 255.0
    );
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

vec4 voxel(vec3 pos, int cascade) {
    float scale = 0.125 * pow(2.0, float(cascade));
    ivec3 coords = clamp(ivec3(scale * pos + 32), 0, 63);
    return unpackRGBA(imageLoad(cascades[cascade], coords).r);
}

// more or less based on https://www.shadertoy.com/view/4dX3zl
void main() {
    out_color = vec4(ray_dir, 1.0);

    int cascade = cascadeAt(ray_origin);
    float step_size = voxelSize(cascade);
    ivec3 voxel_pos = ivec3(floor(ray_origin / step_size));
    ivec3 step = ivec3(sign(ray_dir));
    vec3 dt = abs(vec3(step_size) / ray_dir);
    vec3 t_max = (sign(ray_dir) * (vec3(voxel_pos) - ray_origin) + 0.5 * sign(ray_dir) + 0.5) * dt;

    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);
    float t_entry = 0;

    for (int i = 0; i < 1024; ++i) {
        float t_exit = t_entry;
        if (t_max.x < t_max.y) {
            if (t_max.x < t_max.z) {
                t_exit = t_max.x;
                t_max.x += dt.x;
                voxel_pos.x += step.x;
            } else {
                t_exit = t_max.z;
                t_max.z += dt.z;
                voxel_pos.z += step.z;
            }
        } else {
            if (t_max.y < t_max.z) {
                t_exit = t_max.y;
                t_max.y += dt.y;
                voxel_pos.y += step.y;
            } else {
                t_exit = t_max.z;
                t_max.z += dt.z;
                voxel_pos.z += step.z;
            }
        }

        float distance = t_exit - t_entry;
        t_entry = t_exit;

        if (voxel_pos.x >= -32 && voxel_pos.y >= -32 && voxel_pos.z >= -32 &&
            voxel_pos.x < 32 && voxel_pos.y < 32 && voxel_pos.z < 32) {
            vec4 voxel_color = unpackRGBA(imageLoad(cascades[0], voxel_pos + 32).r);
            float opacity = 1.0 - exp(-0.5 * distance);
            float contribution = opacity * (1.0 - acc.a);
            acc.rgb += voxel_color.rgb * contribution;
            acc.a += contribution;
        }
    }

    out_color = (1 - acc.a) * out_color + acc.a * acc;
}
