#version 460

#define MIN_VOXEL_SIZE 0.244140625

layout(location = 0) in vec3 v_ray_origin;
layout(location = 1) in vec3 v_ray_dir;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler3D u_opacity_cascades;
layout(set = 2, binding = 1) uniform sampler3D u_radiance_cascades;

layout(set = 3, binding = 0) uniform UBO {
    uint draw_mode;
};

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
    ivec3 voxel_pos = ivec3(floor(pos / voxel_size)) + ivec3(33, 33, 33);
    return texelFetch(
        u_opacity_cascades,
        ivec3(voxel_pos.x + 66 * cascade, voxel_pos.y + 132, voxel_pos.z),
        0
    ).r;
}

vec4 voxelAt2(vec3 pos, vec3 dir) {
    uint cascade = cascadeAt(pos);
    if (cascade == 8) return vec4(0.0, 0.0, 0.0, 0.0);
    float voxel_size = voxelSize(cascade);
    ivec3 voxel_pos = ivec3(floor(pos / voxel_size)) + ivec3(33, 33, 33);

    // note lookup face opposite to storage face
    uvec3 faces = uvec3(
        (dir.x > 0) ? 1 : 0,  
        (dir.y > 0) ? 3 : 2,  
        (dir.z > 0) ? 5 : 4  
    );
    vec3 weights = abs(dir * dir);
    
    return
        weights[0] * texelFetch(
            u_radiance_cascades,
            ivec3(voxel_pos.x + 66 * cascade, voxel_pos.y + 66 * faces[0], voxel_pos.z),
            0
        ) + weights[1] * texelFetch(
            u_radiance_cascades,
            ivec3(voxel_pos.x + 66 * cascade, voxel_pos.y + 66 * faces[1], voxel_pos.z),
            0
        ) + weights[2] * texelFetch(
            u_radiance_cascades,
            ivec3(voxel_pos.x + 66 * cascade, voxel_pos.y + 66 * faces[2], voxel_pos.z),
            0
        );
}

const vec3 cascade_colors[8] = {
    vec3(1.0, 1.0, 1.0),
    vec3(1.0, 1.0, 0.0),
    vec3(1.0, 0.0, 1.0),
    vec3(0.0, 1.0, 1.0),
    vec3(1.0, 0.0, 0.0),
    vec3(0.0, 1.0, 0.0),
    vec3(0.0, 0.0, 1.0),
    vec3(0.0, 0.0, 0.0),
};

void main() {

    if (draw_mode == 0) {
    
        o_color = vec4(0.5 * v_ray_dir + 0.5, 1.0);

        vec3 pos = v_ray_origin;
        vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);
        float d = 0.0;
    
        for (int i = 0; i < 1024; ++i) {
            float step = 0.5 * voxelSize(cascadeAt(pos));
            d += step;
            pos += step * v_ray_dir;
            float occlusion = voxelAt(pos);
            vec4 voxel_color = vec4(cascade_colors[cascadeAt(pos)], occlusion);
            voxel_color = vec4(voxel_color.rgb * exp(-d*0.05), voxel_color.a);
            float a = voxel_color.a;
            acc.rgb += voxel_color.rgb * a * (1.0 - acc.a);
            acc.a += a * (1.0 - acc.a);

            if (acc.a > 0.99) break;
        }

        o_color = (1.0 - acc.a) * o_color + acc.a * acc;

    } else if (draw_mode == 1) {
        
        o_color = vec4(0.5 * v_ray_dir + 0.5, 1.0);

        vec3 pos = v_ray_origin;
        vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);

        for (int i = 0; i < 1024; ++i) {
            float step = 0.5 * voxelSize(cascadeAt(pos));
            pos += step * v_ray_dir;
            vec4 rad = voxelAt2(pos, v_ray_dir);
            float a = rad.a;
            acc.rgb += rad.rgb * a * (1.0 - acc.a);
            acc.a += a * (1.0 - acc.a);

            if (acc.a > 0.99) break;
        }
        
        o_color = (1.0 - acc.a) * o_color + acc.a * acc;
        
    }
}
