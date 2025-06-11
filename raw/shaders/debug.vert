#version 460

layout(location = 0) in vec3 a_position;

layout(location = 0) out vec3 v_ray_origin;
layout(location = 1) out vec3 v_ray_dir;

layout(set = 1, binding = 0) uniform DrawData {
    mat4 v_matrix_inv;
    mat4 p_matrix_inv;
} draw_data;

void main() {
    vec4 near = draw_data.p_matrix_inv * vec4(a_position.xy, -1.0, 1.0);
    vec4 far = draw_data.p_matrix_inv * vec4(a_position.xy, 1.0, 1.0);
    near /= near.w;
    far /= far.w;
    vec3 src = (draw_data.v_matrix_inv * vec4(near.xyz, 1.0)).xyz;
    vec3 dst = (draw_data.v_matrix_inv * vec4(far.xyz, 1.0)).xyz;

    v_ray_origin = (draw_data.v_matrix_inv * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    v_ray_dir = normalize(dst - src); 

    gl_Position = vec4(a_position, 1.0);
}
