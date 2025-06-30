#version 460

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_position_light_space;

layout(location = 0) out vec2 o_normal;

#include "include/octahedral.glsl"

void main() {
    o_normal = encodeOctahedral(v_normal);
}
