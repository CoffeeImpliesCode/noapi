# noapi module

Public API files do not call Vulkan. `VkBackend.zig` owns Vulkan calls; `vk.zig` is generated from the Khronos registry and must not be hand-edited.

## Change map

- Add a command-recording API in `CommandBuffer.zig` and implement it in `VkBackend.zig`.
- Use `Gpu.Options` or `SurfaceOptions` for initialization and swapchain configuration. Follow these patterns for new `*Options` structs.
- Re-export public types from `root.zig`.

## Contracts

- Use `@enumFromInt(@intFromEnum(value))` only when the enum values match Vulkan. Use an explicit switch otherwise. Keep `LoadOp` at `load=0`, `clear=1`, `dont_care=2`; `CompareOp` at `never=0` through `always=7`; and `BlendFactor` in Vulkan order. Keep `PresentMode` at `fifo=0`, `mailbox=1`, `immediate=2`, `fifo_relaxed=3`.
- `Surface.zig` maps `PresentMode` variants to Vulkan modes in `toVkPresentMode`. Keep that explicit mapping.
- Gate Tracy with `@hasDecl(root, "tracy_impl")`; required declarations in `root.zig` must be `pub`. Use `const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();`.

## Known incomplete behavior

- `GpuArena.create()` lacks a `*Gpu` reference and returns `BackendError`.
- `Buffer`, `bufferCreate`, and `bufferDestroy` are dead code; use `GpuPtr` and `gpuMalloc`.
- `DescriptorPool.alloc*` returns `0` because it has no freelist tracking.
- `gpuHostToDevicePointer` ignores its arguments; BDA support is a stub.
- `Gpu.zig` has duplicate public re-exports from `root.zig`.
