#version 460

layout(location = 0) in vec3 frag_normal;
// these could have been fragment shader uniforms instead
layout(location = 1) in vec3 frag_diffuse;
layout(location = 2) in vec3 frag_emissive;
layout(location = 3) in float frag_roughness;
layout(location = 4) in vec3 frag_position;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler3D cascades_coverage;
layout(set = 2, binding = 1) uniform sampler3D cascades_radiance;

bool inBounds(vec3 position) {
    vec3 a = abs(position);
    float b = max(a.x, max(a.y, a.z));
    return b <= 504.0; // voxel size at cascade 8 is 16, farthest away voxel center is at 63 / 2
}

float sampleCoverageAt(vec3 position, float diameter) {
    uint cascade = uint(clamp(log2(diameter / 0.125), 0, 7) + 0.5);
    float cascade_size = 64.0 * 0.125 * float(1 << cascade);

    vec3 voxel_pos = position / cascade_size + 0.5;
    vec3 cascade_pos = vec3(
        0.125 * (voxel_pos.x + float(cascade)),
        0.5 * voxel_pos.y,
        voxel_pos.z
    );
    vec3 cascade_texel_half = 0.5 / vec3(512.0, 128.0, 64.0);
    vec3 cascade_min = vec3(
        0.125 * float(cascade),
        0.0,
        0.0
    );
    vec3 cascade_max = vec3(
        0.125 * (1.0 + float(cascade)),
        0.5,
        1.0
    );
    vec3 safe_pos = clamp(
        cascade_pos,
        cascade_min + cascade_texel_half,
        cascade_max - cascade_texel_half
    );
    return texture(cascades_coverage, safe_pos).r;
}

float shadowRayDir(vec3 origin, vec3 light_dir, float voxel_size) {
    float scale_factor = 0.2;

    float acc = 0.0;
    origin += 1.8 * light_dir * voxel_size;
    float radius = scale_factor * 1.8 * voxel_size;

    while (acc < 0.95 && inBounds(origin)) {
        float cov = sampleCoverageAt(origin, 2 * radius);
        acc += (1 - acc) * cov;
    
        float distance = radius * (2 + scale_factor);
        radius = distance - radius;
        origin += light_dir * distance;
    }

    return (acc < 0.95) ? acc : 1.0;
}

void main() {
    vec3 light_dir = normalize(vec3(1.0, 2.0, 0.5));
    float light_intensity = 2.0;

    vec3 a = abs(frag_position);
    float b = max(a.x, max(a.y, a.z));
    uint cascade = uint(clamp(log2(b) - 2, 0, 7));
    float voxel_size = 0.125 * float(1 << cascade);

    vec3 rad =
        frag_diffuse * max(0.01,
            light_intensity *
            max(dot(frag_normal, light_dir), 0.0) *
            (1.0 - shadowRayDir(frag_position, light_dir, voxel_size))
        );
    rad += frag_emissive;

    out_color = vec4(rad, 1.0);
}
