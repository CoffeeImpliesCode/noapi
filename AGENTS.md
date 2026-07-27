# NoAPI Graphics API

Zig project presenting a simplified graphics API around Vulkan  + used to  + used bject

## Overview
Vulkan access library + examples in Zig 0.16. Simplified API wrapping Vulkan  + used ly with shader objects (VkShaderEXT), dynamic rendering, descriptor heaps, BDA.

## Sources
- `mr_gpu` (~/projects/codeberg-Games-by-Mason-mr_gpu)
- `no_gfx_api` (~/Projects/github-leotmp-no_gfx_api) — primary reference for API design
- `sokol`, `gpui`

## Stack
- **Language**: Zig 0.16, LLVM backend (`use_llvm = true` on all exes)
- **Vulkan**: 1.4 core, shader objects (`VK_EXT_shader_object`), dynamic rendering, descriptor buffer, BDA, swapchain maintenance1
- **Windowing**: SDL3
- **Profiling**: Tracy (optional, `-Denable-tracy=true`)
- **Shaders**: GLSL → SPIR-V via glslangValidator; loaded at runtime via `Shader.createFromPath`
- **VCS**: jj — DO NOT USE GIT COMMANDS

## Structure
```
noapi/             # Library: public API surface
├── root.zig       # Re-exports all public types
├── Gpu.zig        # Gpu init/deinit, Options struct, shaderCreate, semaphoreCreate, etc.
├── Surface.zig    # Window surface, beginFrame/endFrame, SurfaceOptions, PresentMode
├── CommandBuffer.zig # Command recording (draw, drawIndexed, dispatch, barriers, etc.)
├── VkBackend.zig  # Vulkan backend implementation (~2500 lines)
├── Shader.zig     # Shader struct + create/createFromPath/destroy
├── ShaderHandle.zig, TextureHandle.zig  # Handle types
├── Texture.zig    # Texture descriptors, upload, blit
├── Buffer.zig     # (mostly dead code — use GpuPtr+gpuMalloc instead)
├── DescriptorPool.zig, DescriptorHeap.zig  # Bindless descriptor management
├── Rendering.zig  # Dynamic rendering attachment state + LoadOp/StoreOp enums
├── RasterState.zig, DepthState.zig, BlendState.zig  # GPU state enums
├── GpuArena.zig   # Arena allocator for GPU memory (needs Gpu ref fix)
├── GpuPtr.zig     # GPU memory pointer with cpu/gpu address
├── Semaphore.zig, Queue.zig, Barrier.zig  # Sync primitives
├── vk.zig         # Generated Vulkan bindings (~58,800 lines)
examples/          # 7 example applications
├── 1_triangle/    # Minimal triangle
├── 2_textures/    # Texture 2D
├── 3_3D/          # 3D cube with camera
├── 4_textures_advanced/ # 3D volume cloud raymarching
├── 5_indirect_triangles/ # Indirect draw
├── 6_compute_shaders/    # Compute+t graphics
├── 7_deferred_async_load/ # Deferred rendering
test/              # Unit tests
shaders/           # Pre-compiled SPIR-V (.spv) + GLSL sources
```

## Where to Look

| Task | Location |
|------|----------|
| Add GPU state enum | `noapi/RasterState.zig`, `DepthState.zig`, `BlendState.zig` |
| Add backend command | `noapi/VkBackend.zig` (function) + `noapi/CommandBuffer.zig` (public wrapper) |
| Modify swapchain/present | `noapi/VkBackend.zig` `addWindow`, `recreateSwapchain`, `beginFrame`/`endFrame` |
| Add example | `examples/N_name/main.zig` + `build.zig` |
| Change build options | `build.zig` — frames_in_flight, use_llvm, tracy |
| Fix example shader | `shaders/*.glsl` → compile via glslangValidator |

## Conventions
- Tiger-style: explicit allocators, no hidden allocations, defer everything
- API/Backend separation: public API never touches Vulkan directly
- Column-major matrices (GL/Vulkan convention)
- `SurfaceOptions`/`Gpu.Options` pattern for init configs
- `pub const` required for tracy_impl/tracy_options for `@hasDecl(root, ...)` dispatch
- LoadOp/StoreOp enums map exactly to Vulkan values (load=0, clear=1, dont_care=2)
- PresentMode: fifo (default), mailbox, immediate, fifo_relaxed

## Development
- Use tools, always use `edit` instead of rewriting the file
- Using shell for large edits is unadvised
- Delegate, Delegate, Delegate
- Be as parallel as possible: 20 files to edit -> 20 workers, 8 files touched → 8 workers, 3 research topics → 3 librarians, 5 hard problems → 5 oracles
- Break tasks down, assume subagents are dumb, give full instruction, use many subagents with small tasks each
- Appending task sessions (task_id) preserves full context — always prefer resume over restart

## Anti-patterns (Modern Vulkan)

### Currently enforced in code
- **No direct git commands** — use jj only
- **No VkPipeline** — use `VkShaderEXT` (shader objects) + dynamic state via `vkCmdSet*EXT`
- **No render passes / VkFramebuffer** — use dynamic rendering (`vkCmdBeginRendering`)
- **No VkShaderModule** — `VK_EXT_shader_object` replaces it. SPIR-V goes directly to `VkShaderEXT`
- **No descriptor sets per-object** — bindless descriptor indexing with arrays of 65536 slots
- **No per-draw descriptor binding** — push constants pass indices into the bindless heap
- **No vertex buffers / vertex input** — BDA vertex pulling in shaders (desktop)
- **No staging buffers for upload** — use BDA + persistent mapping (Resizable BAR / UMA)
- **No `usingnamespace`** — removed in Zig 0.16

### Not yet applied (future improvements)
- **No vkQueueSubmit** — should migrate to `vkQueueSubmit2` (sync2) for simpler pipeline barriers
- **No explicit attachment layout transitions** — `VK_KHR_unified_image_layouts` allows using `GENERAL` for everything, removing all attachment barriers
- **No VkDescriptorPool** — `VK_EXT_descriptor_heap` replaces descriptor sets/layouts/pools entirely (requires very recent drivers)
- **No VkPipelineLayout for graphics** — `vkCmdPushDataEXT` can replace push constants, eliminating the need for a pipeline layout on the graphics path

## Remaining Issues
1. GpuArena.create() needs *Gpu reference
2. Buffer struct + methods are dead code
3. DescriptorPool alloc* always returns 0
4. gpuHostToDevicePointer is a stub
5. Gpu.zig has duplicate type re-exports from root.zig

## Commands
```bash
zig build          # Build all examples
zig build test     # Run tests
zig build 1_triangle  # Build specific example
zig build -Denable-tracy=true  # Build with Tracy profiling
glslangValidator -V shaders/file.vert -o shaders/file_vert.spv  # Compile shader
```

## Validation
- `zig build check` for quick errors
- `zig build` full validation
- `ziglint` compliance after every implementation change (Bugs and Style issues, minus `unsafe undefined`)
- Check Vulkan validation errors: `timeout 3 ./zig-out/bin/N_example 2>&1 | strings | grep -i "VAL.ERROR" | wc -l`
- All examples must produce 0 validation errors
