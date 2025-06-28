#version 460

#define MIN_VOXEL_SIZE 0.244140625

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_position_light_space;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_indirect_light;
layout(set = 2, binding = 1) uniform sampler2D u_shadowmap;

// layout(set = 2, binding = 0) uniform sampler3D u_opacity_cascades;
// layout(set = 2, binding = 1) uniform sampler3D u_radiance_cache_cascades;

layout(set = 3, binding = 0) uniform MaterialData {
    vec4 diffuse;
    vec4 emissive;
    float roughness;
} u_material_data;

float computeShadow() {
    vec3 projected = v_position_light_space.xyz / v_position_light_space.w;
    projected.xy = 0.5 * projected.xy + 0.5;
    projected.y = 1.0 - projected.y;
    if (projected.x < 0.0 || projected.x > 1.0 ||
        projected.y < 0.0 || projected.y > 1.0) return 1.0;
    float closest = texture(u_shadowmap, projected.xy).r;
    float current = projected.z;
    float bias = 0.0005;
    return (current + bias > closest) ? 1.0 : 0.0;
}


void main() {

    vec4 indirect_light = texelFetch(u_indirect_light, ivec2(gl_FragCoord.xy), 0);

    // TODO dynamic
    vec3 light_dir = normalize(vec3(-1.0, 2.0, 0.5));
    float light_intensity = 0.5;

    float shadow = computeShadow();

    vec3 rad = u_material_data.diffuse.rgb *
        shadow * light_intensity *
        max(dot(v_normal, light_dir), 0.0);

    rad += u_material_data.emissive.rgb;

    rad += u_material_data.diffuse.rgb * indirect_light.a *
          (indirect_light.rgb + vec3(1e-2, 1e-2, 1e-2));
    
    o_color = vec4(rad, 1.0);

    // o_color = vec4(u_material_data.diffuse.rgb, 1.0);
    // o_color = vec4(indirect_light.w);
    // o_color = vec4((indirect_light.rgb + vec3(1e-2)) * indirect_light.w, 1.0);
    
    // vec3 projected = v_position_light_space.xyz / v_position_light_space.w;
    // o_color = vec4(projected * 0.5 + 0.5, 1.0);
}

