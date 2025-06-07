#version 460

layout(location = 0) in vec2 v_texcoords;

layout(location = 0) out vec4 o_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

void main() {
    vec3 color = texture(tex, v_texcoords).rgb;

    float mix_amount = 3.951e-02;
    mat3 mix_matrix = mat3(
        1 - 2 * mix_amount, mix_amount, mix_amount,
        mix_amount, 1 - 2 * mix_amount, mix_amount,
        mix_amount, mix_amount, 1 - 2 * mix_amount
    );
    color = color * mix_matrix;
    color = color * (1 + color / 1.332e+03) / (color + 1.471e-01);

    o_color = vec4(color, 1.0);
}
