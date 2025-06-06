#version 460

layout(location = 0) in vec3 pos;
layout(location = 1) in vec3 normal;

layout(location = 0) out vec3 frag_normal;
// these could have been fragment shader uniforms instead
layout(location = 1) out vec3 frag_diffuse;
layout(location = 2) out vec3 frag_emissive;
layout(location = 3) out float frag_roughness;
layout(location = 4) out vec3 frag_position;

layout(set = 1, binding = 0) uniform DrawData {
    mat4 mvp_matrix;
    mat4 normal_matrix;
    mat4 model_matrix;
    vec4 diffuse;
    vec4 emissive;
    float roughness;
} draw_data;

void main() {
    gl_Position = draw_data.mvp_matrix * vec4(pos, 1.0); 
    frag_normal = normalize(mat3(draw_data.normal_matrix) * normal);
    frag_diffuse = draw_data.diffuse.rgb;
    frag_emissive = draw_data.emissive.rgb;
    frag_roughness = draw_data.roughness;
    frag_position = (draw_data.model_matrix * vec4(pos, 1.0)).xyz;
}
