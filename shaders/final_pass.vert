#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Fullscreen quad vertex shader.
// Reads vertex data from GPU buffer reference passed via push constants.

layout(buffer_reference, std430) readonly buffer VertexBuffer {
    vec3 pos;
    vec2 uv;
};

layout(buffer_reference, std430) readonly buffer VertData {
    VertexBuffer verts;
};

layout(push_constant) uniform PushBlock {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
} push;

layout(location = 0) out vec2 vUv;

void main() {
    VertData d = VertData(push.vertData);
    VertexBuffer verts = d.verts;

    vec3 pos = verts.pos;
    vec2 uv  = verts.uv;

    gl_Position = vec4(pos, 1.0);
    vUv = uv;
}
