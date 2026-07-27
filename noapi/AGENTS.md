# noapi — Public API Library

## Overview
The public API surface for the noapi Vulkan abstraction. API/Backend separation: public files never touch Vulkan directly (except `vk.zig` — generated bindings).

## Structure
```
noapi/
├── root.zig        # Re-exports all public types
├── Gpu.zig         # Device lifecycle, Options struct, queue submit
├── Surface.zig     # Window surface, swapchain, PresentMode
├── CommandBuffer.zig  # 24 Tracy-zoned recording methods
├── VkBackend.zig   # ~2500-line Vulkan backend (all vk calls here)
├── Shader.zig      # Shader.create/createFromPath/destroy
├── Rendering.zig   # Rendering attachment state (LoadOp/StoreOp fixed)
├── RasterState.zig, DepthState.zig, BlendState.zig  # GPU state enums
├── DescriptorPool.zig, DescriptorHeap.zig  # Bindless descriptors
├── GpuArena.zig, GpuPtr.zig  # GPU memory management
├── Semaphore.zig, Queue.zig, Barrier.zig  # Sync primitives
└── vk.zig          # 58,800-line generated Vulkan bindings
```

## Where to Look

| Task | Location |
|------|----------|
| Add new API method | Add to CommandBuffer.zig + implement in VkBackend.zig |
| Fix enum values vs Vulkan | Check `@enumFromInt(@intFromEnum(...))` conversions in VkBackend.zig |
| Add Tracy zone | `const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();` |
| Add Options struct | Follow `SurfaceOptions` / `Gpu.Options` pattern |
| Change swapchain config | `SurfaceOptions` (present_mode) / `Gpu.Options` (frames_in_flight) |

## Conventions (specific to noapi/)
- **MANDATORY — tools over shell**: file changes go through `edit`/`write` only. NEVER patch files with inline python/perl/sed/awk scripts, heredocs, or `echo >` redirection — this corrupts files and bypasses review. Read with `read`, search with `grep`/`glob`. Shell is for builds/tests and one-shot fact queries only. If an `edit` fails, read and retry with exact text — never fall back to scripting.
- `*Options` structs for init config (never raw parameters)
- `@enumFromInt(@intFromEnum(...))` ONLY when enum values match Vulkan exactly — use explicit switch otherwise
- Enum values MUST match Vulkan's `i32` values when used with `@enumFromInt`:
  - `LoadOp`: load=0, clear=1, dont_care=2
  - `CompareOp`: never=0..always=7 (explicitly set)
  - `BlendFactor`: zero..one_minus_dst_alpha interleaved per Vulkan order
  - `PresentMode`: fifo=0, mailbox=1, immediate=2, fifo_relaxed=3
- Tracy compile-time gated by `@hasDecl(root, "tracy_impl")` — root file MUST have `pub` declarations
- VkBackend.zig is the ONLY file that calls Vulkan C functions

## Remaining Issues
1. `GpuArena.create()` needs `*Gpu` ref (calls stub → `BackendError`)
2. `Buffer` struct + `bufferCreate`/`bufferDestroy` are dead code (use `GpuPtr` + `gpuMalloc`)
3. `DescriptorPool.alloc*` always returns 0 (no freelist tracking)
4. `gpuHostToDevicePointer` ignores args (BDA stub)
5. `Gpu.zig` has duplicate `pub const` re-exports from `root.zig`
