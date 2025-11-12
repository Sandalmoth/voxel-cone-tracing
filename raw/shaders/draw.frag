#version 460

#include "include/defines.glsl"

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_position_light_space;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_shadowmap;
layout(set = 2, binding = 1) uniform sampler3D u_energy_cascades;
layout(set = 2, binding = 2) uniform sampler3D u_color_cascades;

layout(set = 3, binding = 0) uniform CascadeData {
    uvec4 cascade_size; // xyz
    uvec4 cascade_mask;
    uint n_cascades;
    float min_voxel_size;
    vec4 anchors[MAX_CASCADES];
    vec4 light_direction;
};
layout(set = 3, binding = 1) uniform MaterialData {
    vec4 diffuse;
    vec4 emissive;
    float roughness;
} u_material_data;

#include "include/voxel_utils.glsl"

const float PI = 3.141592653589793;
const float sqrt_3_over_4pi = sqrt(3.0/(4.0 * PI));
const float inv_sqrt_4pi = 1.0 / sqrt(4.0 * PI);

// https://learnopengl.com/Advanced-Lighting/Shadows/Shadow-Mapping
float computeShadow() {
    vec3 projected = v_position_light_space.xyz / v_position_light_space.w;
    projected.xy = 0.5 * projected.xy + 0.5;
    projected.y = 1.0 - projected.y;
    if (projected.x < 0.0 || projected.x > 1.0 ||
        projected.y < 0.0 || projected.y > 1.0) return 0.0;

    float current = projected.z;
    float bias = 0.0005;

    float shadow = 0.0;
    vec2 texel_size = 1.0 / textureSize(u_shadowmap, 0);
    for(int x = -1; x <= 1; ++x)
    {
        for(int y = -1; y <= 1; ++y)
        {
            float closest = texture(u_shadowmap, projected.xy + vec2(x, y) * texel_size).r; 
            shadow += current + bias > closest ? 1.0 : 0.0;        
        }    
    }
    shadow /= 9.0;

    return shadow;
}

vec3 diffuse_cones[6] = {
    vec3(0, 1, 0),
    vec3(0, 0.5, 0.866025),
    vec3(0.823639, 0.5, 0.267617),
    vec3(0.509037, 0.5, -0.700629),
    vec3(-0.509037, 0.5, -0.700629),
    vec3(-0.823639, 0.5, 0.267617)
};
float cone_weights[6] = {0.25, 0.15, 0.15, 0.15, 0.15, 0.15};

// https://www.reedbeta.com/blog/hash-functions-for-gpu-rendering/
uint pcg_hash(uint seed) {
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

vec3 randomVec(uint seed) {
    // not really uniform, but it's not that important
    uint r = pcg_hash(seed);
    return normalize(vec3(
        float((r >> 0) & 0x3FFu) / 1023.0 - 0.5,
        float((r >> 10) & 0x3FFu) / 1023.0 - 0.5,
        float((r >> 20) & 0x3FFu) / 1023.0 - 0.5
    ));
}

mat3 getAlignmentMatrix(vec3 normal, uint seed) {
    // TODO maybe add a fallback if the random vector is too close to the normal
    vec3 random_vector = randomVec(seed);
    vec3 tangent   = normalize(random_vector - normal * dot(random_vector, normal));
    vec3 bitangent = cross(normal, tangent);
    return mat3(bitangent, normal, tangent);
}
float absmax(vec3 v) {
    vec3 a = abs(v);
    return max(max(a.x, a.y), a.z);
}

vec4 gatherRadiance(vec3 origin, vec3 normal, vec3 dir) {
    const float initial_step = 1.5 / absmax(normal);

    float fcascade = cascadeAtFractional(origin);
    uint cascade = uint(fcascade);    
    float first_cascade_fraction = 1.0 - fract(fcascade);
    
    float radius = 0.5 * voxelSize(cascade);
    vec4 basis = vec4(-dir * sqrt_3_over_4pi, inv_sqrt_4pi);

    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);
    float ocl = 0.0;

    while (cascade < n_cascades) {
        vec3 pos = origin + normal * initial_step * min_voxel_size
                          + dir * 2.0 * min_voxel_size * float((1 << cascade) - 1);
        vec3 cascade_world_size = vec3(cascade_size.xyz) * voxelSize(cascade);
        vec3 uvw = (pos - anchors[cascade].xyz) / cascade_world_size + 0.5;
        float energy = dot(basis, texture(u_energy_cascades, vec3(
            (uvw.x + float(cascade)) / float(n_cascades),
            uvw.yz
        )));
        vec4 color = texture(u_color_cascades, vec3(
            (uvw.x + float(cascade)) / float(n_cascades),
            uvw.yz
        ));
        // color.rgb *= energy / (1 + radius);
        color.rgb *= energy;

        color *= first_cascade_fraction;
        first_cascade_fraction = 1.0;

        acc.rgb += (1 - acc.a) * color.a * color.rgb;
        acc.a += (1 - acc.a) * color.a;

        ocl += (1 - ocl) * color.a / (1 + radius);

        radius *= 2;
        cascade += 1;
    }

    return vec4(acc.rgb, ocl);
}


void main() {
    vec3 light_dir = normalize(light_direction.xyz);
    float light_intensity = 0.5; // TODO should also be dynamic

    uint seed = floatBitsToUint(v_position.x) * 3 +
                floatBitsToUint(v_position.y) * 5 +
                floatBitsToUint(v_position.z) * 7;
    vec4 bounced = vec4(0.0, 0.0, 0.0, 0.0);
    mat3 amat = getAlignmentMatrix(v_normal, seed);
    for (int i = 0; i < diffuse_cones.length(); ++i) {
        bounced += cone_weights[i] * gatherRadiance(v_position, v_normal, amat * diffuse_cones[i]);
    }
    bounced.a = 1.0 - bounced.a;
    vec4 gi = vec4(0.0, 0.0, 0.0, bounced.a); // just AO

    float shadow = computeShadow();

    vec3 rad = vec3(0.0);

    rad += u_material_data.diffuse.rgb *
        shadow * light_intensity *
        max(dot(v_normal, light_dir), 0.0);

    rad += u_material_data.emissive.rgb;

    const float gi_factor = 1.0;
    const float ao_power = 1.0;
    const vec3 ambient = vec3(5e-2);
    // vec4 gi = texelFetch(u_gi, ivec2(gl_FragCoord.xy), 0);
    // gi.r = max(0, gi.r);
    // gi.g = max(0, gi.g);
    // gi.b = max(0, gi.b);
    rad += u_material_data.diffuse.rgb * pow(gi.a, ao_power) *
          (gi_factor * gi.rgb + vec3(5e-2));
   
    o_color = vec4(rad, 1.0);
}

