#version 460

layout(location = 0) in vec2 frag_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;


void main() {
    // vaguely agx inspired tonemap that i arrived on after playing around for a bit
    // https://iolite-engine.com/blog_posts/minimal_agx_implementation
    // was a helpful resource
    // i should play around more with tonemapping in the future

    vec3 color = texture(tex, frag_uv).rgb;

    float mix_amount = 3.952e-02;
    mat3 mix_matrix = mat3(
        1 - 2 * mix_amount, mix_amount, mix_amount,
        mix_amount, 1 - 2 * mix_amount, mix_amount,
        mix_amount, mix_amount, 1 - 2 * mix_amount
    );
    // float unmix_amount = 0.1;
    // mat3 unmix_matrix = mat3(
    //     1 + 2 * unmix_amount, -unmix_amount, -unmix_amount,
    //     -unmix_amount, 1 + 2 * unmix_amount, -unmix_amount,
    //     -unmix_amount, -unmix_amount, 1 + 2 * unmix_amount
    // );

    color = color * mix_matrix;
    color = color / (color + 1.468e-01);
    // color = color * unmix_matrix;

    out_color = vec4(color, 1.0);
}
