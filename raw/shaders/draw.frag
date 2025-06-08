#version 460

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;

layout(location = 0) out vec4 o_color;

layout(set = 3, binding = 0) uniform MaterialData {
    vec4 diffuse;
    vec4 emissive;
    float roughness;
} u_material_data;

void main() {
    o_color = vec4(u_material_data.diffuse.rgb, 1.0);
}

