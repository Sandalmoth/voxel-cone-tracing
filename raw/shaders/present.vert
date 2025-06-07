#version 460

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec2 a_texcoords;

layout(location = 0) out vec2 v_texcoords;

void main() {
    v_texcoords = a_texcoords;

    gl_Position = vec4(a_position, 1.0); 
}
