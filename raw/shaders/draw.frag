#version 460

#define MIN_VOXEL_SIZE 0.244140625

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D u_indirect_light;

// layout(set = 2, binding = 0) uniform sampler3D u_opacity_cascades;
// layout(set = 2, binding = 1) uniform sampler3D u_radiance_cache_cascades;

layout(set = 3, binding = 0) uniform MaterialData {
    vec4 diffuse;
    vec4 emissive;
    float roughness;
} u_material_data;


void main() {

    // TODO dynamic
    // vec3 light_dir = normalize(vec3(-1.0, 2.0, 0.5));
    // float light_intensity = 0.5;

    // vec3 rad = u_material_data.diffuse.rgb * max(0.01,
    //     light_intensity *
    //     max(dot(v_normal, light_dir), 0.0)
    // );
    // rad += u_material_data.emissive.rgb;

    // uint seed = uint(gl_FragCoord.x) + uint(gl_FragCoord.y) * 65536u;
    // mat3 amat = getAlignmentMatrix(v_normal, seed);
    // vec4 bounced = vec4(0.0, 0.0, 0.0, 0.0);
    // bounced += gatherRadiance(v_position, v_normal, amat * diffuse_cones[0], false);
    // for (int i = 1; i < 6; ++i) {
    //     bounced += gatherRadiance(v_position, v_normal, amat * diffuse_cones[i], true);
    // }
    // // rad += u_material_data.diffuse.rgb * bounced;
    // rad = u_material_data.diffuse.rgb * (1.0 - bounced.a / 6.0) *
    //       (bounced.rgb + vec3(1e-2, 1e-2, 1e-2));
    // // rad = vec3(1.0 - bounced.a / 6.0);
    
    // o_color = vec4(rad, 1.0);

    // o_color = vec4(u_material_data.diffuse.rgb, 1.0);
    vec4 indirect_light = texelFetch(u_indirect_light, ivec2(gl_FragCoord.xy), 0);
    // o_color = vec4(indirect_light.w);
    o_color = vec4((indirect_light.rgb + vec3(1e-2)) * indirect_light.w, 1.0);
}

