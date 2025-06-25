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
    vec3 faces = vec3(
        (dir.x > 0) ? 1 : 0,  
        (dir.y > 0) ? 3 : 2,  
        (dir.z > 0) ? 5 : 4  
    );
    vec3 weights = abs(dir) / (abs(dir.x) + abs(dir.y) + abs(dir.z));
    // vec3 weights = dir * dir;
    return
        weights[0] * texture(u_radiance_cache_cascades, vec3(
            0.125 * (uvw.x + float(cascade)),
            (1.0 / 6.0) * (uvw.y + faces[0]),
            uvw.z
        )) +
        weights[1] * texture(u_radiance_cache_cascades, vec3(
            0.125 * (uvw.x + float(cascade)),
            (1.0 / 6.0) * (uvw.y + faces[1]),
            uvw.z
        )) +
        weights[2] * texture(u_radiance_cache_cascades, vec3(
            0.125 * (uvw.x + float(cascade)),
            (1.0 / 6.0) * (uvw.y + faces[2]),
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

vec3 gatherRadiance(vec3 origin, vec3 normal, vec3 dir, bool skip) {
    float diameter = clamp(
        0.5 * MIN_VOXEL_SIZE * absmax(origin),
        MIN_VOXEL_SIZE,
        MIN_VOXEL_SIZE * 128
    );

    // TODO see if we could improve on this
    // 2.6 > 1.5 * sqrt(3)
    // so even if we are at the corner of a voxel moving diagonally through
    // we'll never sample the voxel we're starting in
    const float initial_step = 2.0 * absmax(normal);
    origin += normal * diameter * initial_step;

    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);
    float d = diameter * initial_step;
    while (acc.a < 0.95 && inBounds(origin) && diameter < 512.0) {
        vec4 rad = sampleRadianceAtDiameter(origin, dir, diameter);
        // acc.rgb += (1 - acc.a) * rad.rgb *
               // exp(-0.002 * d * d);
               // exp(-1 * diameter * diameter);
        // acc.rgb += (1 - acc.a) * rad.a * rad.rgb / (d * d);
        if (skip) {
            skip = false;
        } else {
            acc.rgb += (1 - acc.a) * rad.a * rad.rgb / (diameter * MIN_VOXEL_SIZE);
            acc.a += (1 - acc.a) * rad.a;
        }
        // acc.a += (1 - acc.a) * rad.a;
        d += diameter;
        origin += 1.25 * dir * diameter;
        diameter = 1.618 * diameter;
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

// https://www.reedbeta.com/blog/hash-functions-for-gpu-rendering/
uint pcg_hash(uint seed) {
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

vec3 diffuse_cones[6] = {
    // vec3(0.0, 1.0, 0.0),        
    // 30 degree elevation
    // vec3(0.8660254037844387, 0.49999999999999994, 0.0),
    // vec3(0.2676165673298175, 0.49999999999999994, 0.823639103546332),
    // vec3(-0.7006292692220367, 0.49999999999999994, 0.5090369604551274),
    // vec3(-0.7006292692220369, 0.49999999999999994, -0.5090369604551271),
    // vec3(0.2676165673298173, 0.49999999999999994, -0.8236391035463321),
    // 40 degree elevation
    // vec3(0.766044443118978, 0.6427876096865393, 0.0),
    // vec3(0.23672075137025697, 0.6427876096865393, 0.7285515593999962),
    // vec3(-0.6197429729297459, 0.6427876096865393, 0.45026962626593564),
    // vec3(-0.6197429729297461, 0.6427876096865393, -0.4502696262659355),
    // vec3(0.2367207513702568, 0.6427876096865393, -0.7285515593999962),
    // 50 degree elevation
    // vec3(0.6427876096865394, 0.766044443118978, 0.0),
    // vec3(0.19863229516679126, 0.766044443118978, 0.611327344786169),
    // vec3(-0.5200261000100609, 0.766044443118978, 0.37782107733007836),
    // vec3(-0.520026100010061, 0.766044443118978, -0.3778210773300782),
    // vec3(0.19863229516679112, 0.766044443118978, -0.6113273447861691),
    
    // off angle
    vec3(0.0, 0.9659258262890683, 0.25881904510252074),
    vec3(0.7660444431189781, 0.6208851530148457, 0.16636567534280192),
    vec3(0.236720751370257, 0.4323221341029862, 0.8700924423504325),
    vec3(-0.619742972929746, 0.5043467983060274, 0.6012927361465958),
    vec3(-0.6197429729297461, 0.7374235077236639, -0.2685613854609918),
    vec3(0.23672075137025683, 0.8094481719267052, -0.5373610916648287),
};

vec3 randomHelper(vec3 normal, uint seed) {
    float u = float(pcg_hash(seed)) / 4294967296.0;
    float angle = u * 6.28318530718;
    vec3 notN = abs(normal.y) < 0.999 ? vec3(0, 1, 0) : vec3(1, 0, 0);
    vec3 tangent = normalize(cross(normal, notN));
    vec3 bitangent = cross(normal, tangent);
    return cos(angle) * tangent + sin(angle) * bitangent;
}

mat3 getAlignmentMatrix(vec3 normal, uint seed) {
    vec3 new_y = normalize(normal);

    // vec3 helper = vec3(0.0, 1.0, 0.0);
    // if (abs(dot(new_y, helper)) > 0.999) {
    //     helper = vec3(1.0, 0.0, 0.0);
    // }
    vec3 helper = randomHelper(normal, seed);

    vec3 new_x = normalize(cross(helper, new_y));
    vec3 new_z = cross(new_y, new_x);
    return mat3(new_x, new_y, new_z);
}

void main() {

    // TODO dynamic
    vec3 light_dir = normalize(vec3(-1.0, 2.0, 0.5));
    float light_intensity = 0.5;

    vec3 rad = u_material_data.diffuse.rgb * max(0.01,
        light_intensity *
        max(dot(v_normal, light_dir), 0.0)
    );
    rad += u_material_data.emissive.rgb;

    uint seed = uint(gl_FragCoord.x) + uint(gl_FragCoord.y) * 65536u;
    mat3 amat = getAlignmentMatrix(v_normal, seed);
    vec3 bounced = vec3(0.0, 0.0, 0.0);
    bounced += gatherRadiance(v_position, v_normal, amat * diffuse_cones[0], false);
    for (int i = 1; i < 6; ++i) {
        bounced += gatherRadiance(v_position, v_normal, amat * diffuse_cones[i], true);
    }
    // rad += u_material_data.diffuse.rgb * bounced;
    rad = u_material_data.diffuse.rgb * bounced;
    
    o_color = vec4(rad, 1.0);
    o_normal = encodeOctahedral(v_normal);

    // o_color = vec4(u_material_data.diffuse.rgb, 1.0);
}

