struct VertexInput {
    @location(0) position: vec2f,
    @location(1) uv: vec2f,
}

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

struct FadeData {
    fade: f32,
    padding0: u32,
    padding1: u32,
    padding2: u32,
}

@group(0) @binding(0) var texture_a: texture_2d<f32>;
@group(0) @binding(1) var texture_b: texture_2d<f32>;
@group(0) @binding(2) var texture_sampler: sampler;
@group(0) @binding(3) var<uniform> fade_data: FadeData;

@vertex
fn vertex_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;
    output.position = vec4f(input.position, 0.0, 1.0);
    output.uv = input.uv;
    return output;
}

@fragment
fn fragment_main(input: VertexOutput) -> @location(0) vec4f {
    let color_a = textureSample(texture_a, texture_sampler, input.uv);
    let color_b = textureSample(texture_b, texture_sampler, input.uv);
    return mix(color_a, color_b, fade_data.fade);
}
