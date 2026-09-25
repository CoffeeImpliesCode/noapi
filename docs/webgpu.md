# Browser WebGPU backend

`zig build` keeps Vulkan as the native backend. `zig build web` builds a separate WebAssembly target with WebGPU. The browser target runs the triangle and two-texture examples. It does not build the other five examples for the browser.

## Run the examples

Use the project devenv, which provides Zig and Emscripten (`emcc`). From the repository root:

```sh
direnv exec . zig build web
python3 -m http.server 8000 --directory zig-out/web
```

Open `http://localhost:8000/?example=1_triangle` or `http://localhost:8000/?example=2_textures` in a WebGPU-capable browser. The page reports an error if WebGPU or an adapter is unavailable. Serve the files over localhost or HTTPS. Do not open `index.html` with a `file:` URL.

The web entry uses the same `Gpu`, `Surface`, `Shader`, `Texture`, and `CommandBuffer` APIs as the native examples. The browser creates the WebGPU device and canvas context before it starts WebAssembly. `web/noapi-webgpu.js` connects the Zig backend to that device. The page drives `noapiFrame` with `requestAnimationFrame`. The texture WGSL is embedded from `web/textures.wgsl`; the triangle WGSL is generated during the build.

## Shared Slang triangle

`shaders/triangle.slang` is compiled by `slangc` to native SPIR-V under `zig-out/shaders/` and to WGSL in the browser build cache. The browser build embeds the generated WGSL in WebAssembly. `slangc` is provided by the project devenv.

The native vertex shader dereferences the real Vulkan buffer address in `PushData.vert_data`. On WebGPU, `GpuPtr.gpu` encodes `(buffer ID << 32) | byte offset`; it is not a GPU address. `GpuPtr.offset()` can select a suballocation without changing the public API. For the triangle draw, the backend resolves this token to one live, read-only storage buffer and passes its byte offset as a uniform. The shared shader reads the same 32-byte vertex records through `ByteAddressBuffer.Load4` on WebGPU. The browser uploads the CPU-mapped buffer on each draw.

This is a limited graphics-data path, not general pointer emulation: the offset must be four-byte aligned and inside an allocation, and the buffer must fit `maxStorageBufferBindingSize`. It does not support arbitrary pointer casts, pointer chasing, shader writes, or bindless buffers. The texture example still uses its original GLSL/SPIR-V shaders on native and hand-written WGSL in the browser. The existing viewport conventions make the native triangle appear vertically inverted relative to the browser triangle.

## Supported operations and limits

The WebGPU backend supports one canvas surface, FIFO presentation, one color attachment, RGBA8 2D textures, two texture slots, vertex and index buffers, and indexed or non-indexed draws. The texture example uploads two checkerboards and uses a uniform fade value. WebGPU handles resource hazards, so a command buffer barrier does not submit a separate barrier.

The WebGPU backend does not support SPIR-V shader objects, arbitrary buffer device addresses, descriptor heaps, compute, readback, timestamp queries, timeline semaphores, or a synchronous `waitIdle`. Use `Shader.createWgsl` and `Surface.initWeb` in browser code. Do not pass `GpuPtr.gpu` to WGSL as a native address. Unsupported operations return an error when the API permits one. Unsupported command-buffer calls fail the frame instead of silently drawing incorrect output. The Vulkan backend itself is unchanged.

Some headless browser software adapters can lose the WebGPU device. For a visual check, use a browser with a working hardware WebGPU adapter.
