#version 460

#define MIN_VOXEL_SIZE 0.244140625

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;

layout(location = 0) out vec4 o_color;
layout(location = 1) out vec2 o_normal;

layout(set = 2, binding = 0) uniform sampler3D u_opacity_cascades;

layout(set = 3, binding = 0) uniform MaterialData {
    vec4 diffuse;
    vec4 emissive;
    float roughness;
} u_material_data;

float absmax(vec3 v) {
    vec3 a = abs(v);
    return max(max(a.x, a.y), a.z);
}

uint cascadeAt(vec3 pos) {
    float maximum = absmax(pos);
    return uint(clamp(ceil(log2(maximum / (MIN_VOXEL_SIZE * 32))), 0, 8));
}

float voxelSize(uint cascade) {
    return MIN_VOXEL_SIZE * float(1 << cascade);
}

bool inBounds(vec3 position) {
    return absmax(position) <= 1000.0;
}

float sampleOpacityAt(vec3 position, uint cascade) {
    float cascade_world_size = 66.0 * MIN_VOXEL_SIZE * float(1 << cascade);
    vec3 uvw = position / cascade_world_size + 0.5;
    // cannot happen
    // if (uvw.x < 0.0 || uvw.x > 1.0 || uvw.y < 0.0 || uvw.y > 1.0 ||
    //     uvw.z < 0.0 || uvw.z > 1.0) {
    //     return 0.0;
    // }
    return texture(u_opacity_cascades, vec3(
        0.125 * (uvw.x + float(cascade)),
        (1.0 / 3.0) * uvw.y + 2.0 / 3.0,
        uvw.z
    )).r;
}

float sampleOpacityAtDiameter(vec3 position, float diameter) {
    float fcascade = clamp(log2(diameter / MIN_VOXEL_SIZE), 0, 7);
    uint low_cascade = uint(fcascade);
    uint high_cascade = min(low_cascade + 1, 7);
    float frac = fract(fcascade);
    float low = sampleOpacityAt(position, low_cascade);
    float high = sampleOpacityAt(position, high_cascade);
    return (1 - frac) * low + frac * high;
}

float shadowRay(vec3 origin, vec3 normal, vec3 light_dir) {
    float diameter = clamp(
        0.5 * MIN_VOXEL_SIZE * absmax(origin),
        MIN_VOXEL_SIZE,
        MIN_VOXEL_SIZE * 128
    );

    // TODO see if we could improve on this
    // 2.6 > 1.5 * sqrt(3)
    // so even if we are at the corner of a voxel moving diagonally through
    // we'll never sample the voxel we're starting in
    origin += normal * diameter * 2.6;

    float acc = 0.0;
    while (acc < 0.99 && inBounds(origin)) {
        float cov = sampleOpacityAtDiameter(origin, diameter);
        acc += (1 - acc) * cov;
        origin += light_dir * diameter;
        diameter = clamp(1.5 * diameter, MIN_VOXEL_SIZE, MIN_VOXEL_SIZE * 128);
    }

    return (acc > 0.99) ? 1.0 : acc;
}

// https://jcgt.org/published/0003/02/01/
vec2 signNotZero(vec2 v) {
    return vec2((v.x >= 0.0) ? +1.0 : -1.0, (v.y >= 0.0) ? +1.0 : -1.0);
}
vec2 encodeOctahedral(vec3 v) {
    vec2 p = v.xy * (1.0 / (abs(v.x) + abs(v.y) + abs(v.z)));
    return (v.z <= 0.0) ? ((1.0 - abs(p.yx)) * signNotZero(p)) : p;
}
vec3 decodeOctahedral(vec2 e) {
    vec3 v = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
    if (v.z < 0) v.xy = (1.0 - abs(v.yx)) * signNotZero(v.xy);
    return normalize(v);
}

void main() {

    vec3 light_dir = normalize(vec3(-1.0, 2.0, 0.5));
    float light_intensity = 1.0;

    vec3 rad = u_material_data.diffuse.rgb * max(0.01,
        light_intensity *
        max(dot(v_normal, light_dir), 0.0)
    );
    rad += u_material_data.emissive.rgb;
    
    o_color = vec4(rad, 1.0);
    o_normal = encodeOctahedral(v_normal);

    // o_color = vec4(u_material_data.diffuse.rgb, 1.0);
}

