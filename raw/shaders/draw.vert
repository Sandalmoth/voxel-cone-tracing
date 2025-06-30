#version 460

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec3 a_normal;

layout(location = 0) out vec3 v_position;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_position_light_space;

layout(set = 1, binding = 0) uniform TransformData {
    mat4 mvp_matrix;
    mat4 normal_matrix;
    mat4 model_matrix;
    mat4 light_space_matrix;
} u_transform_data;

void main() {
    v_normal = normalize(mat3(u_transform_data.normal_matrix) * a_normal);
    v_position = (u_transform_data.model_matrix * vec4(a_position, 1.0)).xyz;

    v_position_light_space = u_transform_data.light_space_matrix * vec4(v_position, 1.0);

    gl_Position = u_transform_data.mvp_matrix * vec4(a_position, 1.0); 
}
