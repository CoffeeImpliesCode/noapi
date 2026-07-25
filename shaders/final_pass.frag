#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Deferred shading final pass fragment shader.
// Samples G-buffer textures and displays the selected one.

layout(set = 0, binding = 0) uniform texture2D textureHeap[];
layout(set = 0, binding = 2) uniform sampler samplerHeap[];

layout(buffer_reference, std430) readonly buffer FragData {
    uint gbuffer_albedo;
    uint gbuffer_albedo_sampler;
    uint gbuffer_normal;
    uint gbuffer_normal_sampler;
    uint gbuffer_metallic_roughness;
    uint gbuffer_metallic_roughness_sampler;
    int  selected_texture_type;
};

layout(push_constant) uniform PushBlock {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
} push;

layout(location = 0) in  vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
    FragData d = FragData(push.fragData);

    vec4 result;
    if (d.selected_texture_type == 0) {
        result = texture(
            sampler2D(textureHeap[nonuniformEXT(d.gbuffer_albedo)], samplerHeap[nonuniformEXT(d.gbuffer_albedo_sampler)]),
            vUv
        );
    } else if (d.selected_texture_type == 1) {
        result = texture(
            sampler2D(textureHeap[nonuniformEXT(d.gbuffer_normal)], samplerHeap[nonuniformEXT(d.gbuffer_normal_sampler)]),
            vUv
        );
    } else {
        result = texture(
            sampler2D(textureHeap[nonuniformEXT(d.gbuffer_metallic_roughness)], samplerHeap[nonuniformEXT(d.gbuffer_metallic_roughness_sampler)]),
            vUv
        );
    }

    fragColor = result;
}
