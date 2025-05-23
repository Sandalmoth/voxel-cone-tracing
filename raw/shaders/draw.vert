#version 460

layout(location = 0) in vec3 pos;
layout(location = 1) in vec3 normal;

layout(location = 0) out vec3 frag_normal;

layout(set = 1, binding = 0) uniform DrawData {
    mat4 mvp_matrix;
    mat4 normal_matrix;
    // vec3 diffuse;
    // vec3 emissive;
    // float roughness;
} draw_data;

void main() {
    gl_Position = draw_data.mvp_matrix * vec4(pos, 1.0); 
    frag_normal = mat3(draw_data.normal_matrix) * normal;
}
