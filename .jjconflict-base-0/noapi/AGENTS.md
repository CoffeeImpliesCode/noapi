# noapi public API

Public types live under `noapi/` and are re-exported by `root.zig`. Public files do not call Vulkan; `VkBackend.zig` is the only file that calls Vulkan C functions. `vk.zig` is generated bindings.

## Change map

- Add a command method to `CommandBuffer.zig` and implement it in `VkBackend.zig`.
- Use `*Options` structs for initialization. Follow `Gpu.Options` and `SurfaceOptions`; swapchain configuration uses `SurfaceOptions.present_mode` and `Gpu.Options.frames_in_flight`.
- Convert enums with `@enumFromInt(@intFromEnum(...))` only when their values match Vulkan. Otherwise use an explicit switch. Vulkan-mapped values must match Vulkan `i32` values:
  - `LoadOp`: `load=0`, `clear=1`, `dont_care=2`.
  - `CompareOp`: `never=0` through `always=7`.
  - `BlendFactor`: follow Vulkan order from `zero` through `one_minus_dst_alpha`.
  - `PresentMode`: `fifo=0`, `mailbox=1`, `immediate=2`, `fifo_relaxed=3`.
- Tracy is gated by `@hasDecl(root, "tracy_impl")`; root must declare public Tracy symbols. Use `const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();` for a zone.

## Current design notes

- BVH and ray tracing are not implemented; they are deferred.
- Prefer explicit `descHeap` / `DescriptorPool.bindDescriptorSets` over `CommandBuffer.bindTexture`'s private lazy heap.
- Frame pacing is inconsistent: `3_3D`, `5_indirect_triangles`, and `6_compute_shaders` use timeline `frame_sem`; other examples busy-loop on `FrameTimer`.
