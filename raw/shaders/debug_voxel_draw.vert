#version 460

layout(location = 0) in vec3 pos;

layout(location = 0) out vec3 ray_origin;
layout(location = 1) out vec3 ray_dir;

layout(set = 1, binding = 0) uniform DrawData {
    mat4 v_matrix_inv;
    mat4 p_matrix_inv;
} draw_data;

void main() {
    vec4 near = draw_data.p_matrix_inv * vec4(pos.xy, -1.0, 1.0);
    vec4 far = draw_data.p_matrix_inv * vec4(pos.xy, 1.0, 1.0);
    near /= near.w;
    far /= far.w;
    vec3 src = (draw_data.v_matrix_inv * vec4(near.xyz, 1.0)).xyz;
    vec3 dst = (draw_data.v_matrix_inv * vec4(far.xyz, 1.0)).xyz;

    ray_origin = (draw_data.v_matrix_inv * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    ray_dir = normalize(dst - src); 

    gl_Position = vec4(pos, 1.0);
}
