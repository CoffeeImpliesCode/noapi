struct TriangleVertex {
    float4 position;
    float4 color;
};

#if NOAPI_WEB
[[vk::binding(0, 0)]] ByteAddressBuffer vertexBytes;
struct PointerData { uint byteOffset; };
[[vk::binding(1, 0)]] ConstantBuffer<PointerData> pointerData;
#else
struct GraphicsPush {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
};
[[vk::push_constant]] GraphicsPush pushData;
#endif

TriangleVertex loadVertex(uint index) {
#if NOAPI_WEB
    uint offset = pointerData.byteOffset + index * 32;
    TriangleVertex vertex;
    vertex.position = asfloat(vertexBytes.Load4(offset));
    vertex.color = asfloat(vertexBytes.Load4(offset + 16));
    return vertex;
#else
    return ((TriangleVertex*)pushData.vertData)[index];
#endif
}

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId : SV_VertexID) {
    TriangleVertex vertex = loadVertex(vertexId);
    VertexOutput output;
    output.position = vertex.position;
    output.color = vertex.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    return input.color;
}
