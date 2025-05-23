#version 460

layout(location = 0) in vec3 frag_normal;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(0.5 * (1.0 + frag_normal), 1.0);
}
