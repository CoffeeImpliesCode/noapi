# noapi API

Public files define a Vulkan-independent API; `VkBackend.zig` is the only file that calls Vulkan C functions. `vk.zig` contains generated bindings. Re-export public types from `root.zig`.

## Changes

- Add a command method to `CommandBuffer.zig` and implement it in `VkBackend.zig`.
- Use `*Options` structs for initialization. Follow `Gpu.Options` or `SurfaceOptions`; swapchain mode is in `SurfaceOptions`, and frames in flight are in `Gpu.Options`.
- Convert enum values with `@enumFromInt(@intFromEnum(...))` only when values match Vulkan. Otherwise use an explicit switch.
- Values passed through enum conversion must match Vulkan `i32` values: `LoadOp` load=0, clear=1, dont_care=2; `CompareOp` never=0 through always=7; `BlendFactor` zero through one_minus_dst_alpha follow Vulkan's interleaved order; `PresentMode` fifo=0, mailbox=1, immediate=2, fifo_relaxed=3.
- Gate Tracy with `@hasDecl(root, "tracy_impl")`; `root.zig` must expose the needed declarations with `pub`. Add a zone with `const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();`.

## Known incomplete paths

- `GpuArena.create()` needs `*Gpu`; its stub returns `BackendError`.
- `Buffer`, `bufferCreate`, and `bufferDestroy` are dead code. Use `GpuPtr` and `gpuMalloc`.
- `DescriptorPool.alloc*` always returns 0 because it has no freelist.
- `gpuHostToDevicePointer` ignores its arguments; buffer device address is a stub.
- `Gpu.zig` duplicates public re-exports from `root.zig`.
