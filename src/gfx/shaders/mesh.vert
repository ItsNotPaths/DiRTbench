#version 450
layout(set = 1, binding = 0) uniform UBO {
    mat4 mvp;
};
layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 v_color;
void main() {
    gl_Position = mvp * vec4(in_pos, 1.0);
    v_color = in_color;
}
