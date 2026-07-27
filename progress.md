# noapi — Current State & Analysis

**Build**: `zig build` ✓ | `zig build -Denable-tracy=true` ✓  
**Validation**: 0 errors across examples 1-6  
**Tracy**: 42 CPU zones (API) + 15 blocking backend zones (tomato), `-Denable-tracy=true` build option  
**Zig**: 0.16.0, LLVM backend forced on all exes  

## Completed Work

### API Layer
- `SurfaceOptions` struct with `present_mode` (fifo/mailbox/immediate/fifo_relaxed)
- `Surface.init` takes `SurfaceOptions` instead of raw parameters
- Gpu `Options` struct already existed with `frames_in_flight`
- `frames_in_flight` properly propagated from init → backend → window
- `CommandBuffer.zig`: 24 Tracy CPU zones on all recording methods
- `Gpu.zig`: 13 Tracy CPU zones on lifecycle ops
- `Surface.zig`: 3 Tracy CPU zones on frame boundary ops
- `VkBackend.zig`: 15 tomato Tracy zones on blocking calls (waitForFences, acquire, submit, present)

### Backend
- `addWindow` takes `SurfaceOptions` instead of raw extent
- Present mode flows through to swapchain creation (no hardcoded MAILBOX override)
- Swapchain barrier: `old_layout = .undefined` (not `.present_src_khr`)
- `draw_indirect_count = .true` in vk12 features
- Surface formats: picks `b8g8r8a8_srgb + srgb_nonlinear_khr`

### Enums (fixed to match Vulkan values)
- `Rendering.LoadOp`: loads=0, clear=1, dont_care=2
- `Rendering.StoreOp`: store=0, dont_care=1
- `RasterState.Topology`: full Vulkan set with explicit values
- `RasterState.CullMode`: none=0, front=1, back=2, all=3
- `RasterState.FrontFace`: explicit values
- `RasterState.BlendOp`: matches Vulkan by coincidence
- `DepthState.CompareOp`: explicit values
- `BlendState.BlendFactor`: corrected to Vulkan interleaved ordering
- `CommandBuffer.IndexFormat`: u16=0, u32=1, u8, none

### Tracy Setup
- `-Denable-tracy` build option (disabled by default, zero-cost)
- `tracy_impl` module on all 8 executables (enabled/disabled toggle)
- `pub const tracy` + `tracy_impl` + `tracy_options` in all examples (must be `pub` for `@hasDecl(root, ...)`)
- tracy_zig updated to latest commit `39cf5b55`

### Examples
- Uniform FPS output: `"FPS: {d:.1}  frame: {d:.2}ms\n"` every 60 frames
- `Surface.init` uses `SurfaceOptions` with `.extent`
- Render area uses `surf.surfaceSize()` (not SDL `getSizeInPixels`) to prevent resize crash
- `use_llvm = true` on all executables
- 3_3D: default present_mode = .fifo
- Present mode chain: SurfaceOptions → addWindow → swapchain (fully wired)

## Remaining Issues

### 1. GpuArena — needs Gpu reference (P0)
`GpuArena.create()` takes no `*Gpu`, so `gpuMalloc` can't be called → returns `BackendError`.  
**Fix**: `create(gpu: *Gpu, size: usize)` delegate to `gpu.gpuMalloc`.  
**File**: `noapi/GpuArena.zig`

### 2. Gpu.bufferCreate / bufferDestroy — dead code (P0)
Both are no-ops. The codebase uses `GpuPtr` + `gpuMalloc`/`gpuFree` instead (no_gfx_api pattern).  
**Fix**: Wire through backend OR delete `Buffer` struct + methods.  
**File**: `noapi/Gpu.zig`

### 3. Gpu.drawTriangles — dead code (P1)
All args ignored, does nothing. Vestige of dvui pattern. API uses `CommandBuffer.draw[Indexed]` instead.  
**Fix**: Wire to indexed draw OR delete.  
**File**: `noapi/Gpu.zig`

### 4. DescriptorPool alloc* — return 0 (P1)
`allocTexture`/`allocSampler` all return 0 without proper freelist tracking. Works for single allocations but breaks on multiple.  
**Fix**: Implement sequential slot tracking with counters.  
**File**: `noapi/DescriptorPool.zig`

### 5. Gpu.gpuHostToDevicePointer — stub (P1)
Ignores args, returns zeroed GpuPtr. Needs BDA-based implementation or identity mapping.  
**Fix**: `return GpuPtr{ .cpu = cpu_ptr, .gpu = @intFromPtr(cpu_ptr) };`  
**File**: `noapi/Gpu.zig`

### 6. Gpu.zig duplicate type re-exports (P2)
~40 `pub const TextureHandle = @import(...)` at bottom of Gpu.zig duplicates root.zig exports.  
**Fix**: Remove block.  
**File**: `noapi/Gpu.zig`

### 7. Swapchain format selection always picks first (P2)
Line 1531: `var chosen_format: vk.SurfaceFormatKHR = formats[0];` — if b8g8r8a8_srgb isn't first, falls back to first entry.  
**Fix**: More robust format preference loop.  
**File**: `noapi/VkBackend.zig:1531`

### 8. Example frame pacing — no sleep (P2)
All examples busy-loop at CPU speed. With FIFO vsync, Wayland/niri may not block acquire properly → 100% CPU.  
**Fix**: Use `FrameSchedule.next_vblank_us` or `std.time.sleep` for frame pacing.  
**Files**: All examples

## Build Config
- `use_llvm = true` on all 8 executables
- `tracy_impl` module conditional on `-Denable-tracy`
- SDL3, noapi, tracy modules on all exes
- Tracy C++ client force-built at ReleaseFast (Debug → ReleaseFast workaround)
