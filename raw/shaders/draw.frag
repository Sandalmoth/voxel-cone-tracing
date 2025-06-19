#version 460

#define MIN_VOXEL_SIZE 0.244140625

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;

layout(location = 0) out vec4 o_color;
layout(location = 1) out vec2 o_normal;

layout(set = 2, binding = 0) uniform sampler3D u_opacity_cascades;
layout(set = 2, binding = 1) uniform sampler3D u_radiance_cache_cascades;

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

vec4 sampleRadianceAt(vec3 position, vec3 dir, uint cascade) {
    float cascade_world_size = 66.0 * MIN_VOXEL_SIZE * float(1 << cascade);
    vec3 uvw = position / cascade_world_size + 0.5;
    // cannot happen
    // if (uvw.x < 0.0 || uvw.x > 1.0 || uvw.y < 0.0 || uvw.y > 1.0 ||
    //     uvw.z < 0.0 || uvw.z > 1.0) {
    //     return 0.0;
    // }
    vec3 faces = vec3(
        (dir.x > 0) ? 1 : 0,  
        (dir.y > 0) ? 3 : 2,  
        (dir.z > 0) ? 5 : 4  
    );
    vec3 weights = abs(dir) / (abs(dir.x) + abs(dir.y) + abs(dir.z));
    return
        weights[0] * texture(u_radiance_cache_cascades, vec3(
            0.125 * (uvw.x + float(cascade)),
            (1.0 / 6.0) * uvw.y + faces[0] / 6.0,
            uvw.z
        )) +
        weights[1] * texture(u_radiance_cache_cascades, vec3(
            0.125 * (uvw.x + float(cascade)),
            (1.0 / 6.0) * uvw.y + faces[1] / 6.0,
            uvw.z
        )) +
        weights[2] * texture(u_radiance_cache_cascades, vec3(
            0.125 * (uvw.x + float(cascade)),
            (1.0 / 6.0) * uvw.y + faces[2] / 6.0,
            uvw.z
        ));
}

vec4 sampleRadianceAtDiameter(vec3 position, vec3 dir, float diameter) {
    float fcascade = clamp(log2(diameter / MIN_VOXEL_SIZE), 0, 7);
    uint low_cascade = uint(fcascade);
    uint high_cascade = min(low_cascade + 1, 7);
    float frac = fract(fcascade);
    vec4 low = sampleRadianceAt(position, dir, low_cascade);
    vec4 high = sampleRadianceAt(position, dir, high_cascade);
    return (1 - frac) * low + frac * high;
}

vec3 gatherRadiance(vec3 origin, vec3 normal, vec3 dir) {
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

    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);
    float d = 0;
    while (acc.a < 0.99 && inBounds(origin) && d < MIN_VOXEL_SIZE * 512) {
        vec4 rad = sampleRadianceAtDiameter(origin, dir, diameter);
        acc += (1 - acc.a) * rad;
        d += diameter;
        origin += dir * diameter;
        diameter = clamp(1.5 * diameter, MIN_VOXEL_SIZE, MIN_VOXEL_SIZE * 128);
    }

    return acc.rgb;
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

vec3 diffuse_cones[6] = vec3[](
    vec3(0.0, 1.0, 0.0),        
    vec3(0.894427, 0.447214, 0.0),
    vec3(0.276393, 0.447214, 0.850651),
    vec3(-0.723607, 0.447214, 0.525731),
    vec3(-0.723607, 0.447214, -0.525731),
    vec3(0.276393, 0.447214, -0.850651)
);

mat3 getAlignmentMatrix(vec3 normal) {
    vec3 new_y = normalize(normal);
    vec3 helper = vec3(0.0, 1.0, 0.0);
    if (abs(dot(new_y, helper)) > 0.999) {
        helper = vec3(1.0, 0.0, 0.0);
    }
    vec3 new_x = normalize(cross(helper, new_y));
    vec3 new_z = cross(new_y, new_x);
    return mat3(new_x, new_y, new_z);
}

void main() {

    vec3 light_dir = normalize(vec3(-1.0, 2.0, 0.5));
    float light_intensity = 0.5;

    vec3 rad = u_material_data.diffuse.rgb * max(0.01,
        light_intensity *
        max(dot(v_normal, light_dir), 0.0)
    );
    rad += u_material_data.emissive.rgb;

    // mat3 amat = getAlignmentMatrix(v_normal);
    // vec3 bounced = vec3(0.0, 0.0, 0.0);
    // for (int i = 0; i < 6; ++i) {
    //     bounced += gatherRadiance(v_position, v_normal, amat * diffuse_cones[i]);
    // }
    // rad += u_material_data.diffuse.rgb * bounced;
    
    o_color = vec4(rad, 1.0);
    o_normal = encodeOctahedral(v_normal);

    // o_color = vec4(u_material_data.diffuse.rgb, 1.0);
}

