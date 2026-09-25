# noapi — Current State & Analysis

**Build**: `zig build` and `zig build -Denable-tracy=false` pass; `zig build -Doptimize=ReleaseFast` passes.
**Tests**: 58/58 library tests pass in Debug, ReleaseSafe, and ReleaseFast; the offscreen submission check passes in Debug, ReleaseFast, and without Tracy.
**Runtime**: All seven examples reach an FPS report on the NVIDIA GeForce GTX 1660 Ti.
**Zig**: 0.16.0, LLVM backend forced on all executables.

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
- Surface formats prefer `b8g8r8a8_srgb`, then `r8g8b8a8_srgb`, then `b8g8r8a8_unorm`, all with `srgb_nonlinear_khr`. Otherwise, use the first supported format.

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
- `-Denable-tracy` build option (enabled by default; `-Denable-tracy=false` disables instrumentation)
- `tracy_impl` module on all 8 executables (enabled/disabled toggle)
- `pub const tracy` + `tracy_impl` + `tracy_options` in all examples (must be `pub` for `@hasDecl(root, ...)`)
- tracy_zig pinned to commit `b2ea5bf4b8fe80f7cd9226d0c4af88dc04e1e07b`

### Examples
- Uniform FPS output: `"FPS: {d:.1}  frame: {d:.2}ms\n"` every 60 frames
- `Surface.init` uses `SurfaceOptions` with `.extent`
- Render area uses `surf.surfaceSize()` (not SDL `getSizeInPixels`) to prevent resize crash
- `use_llvm = true` on all executables
- 3_3D: default present_mode = .fifo
- Present mode chain: SurfaceOptions → addWindow → swapchain (fully wired)

## Previously Resolved Issues

### 1. GpuArena — RESOLVED
Was: `create()` took no `*Gpu`, `gpuMalloc` unreachable, returned `BackendError`.
Now: `noapi/GpuArena.zig:12` — `create(base: GpuPtr, size: usize)` bump arena atop caller-owned block; `alloc`/`allocT` align forward, panic past `size`; `reset` reuses, `destroy` invalidates.

### 2. Gpu.bufferCreate / bufferDestroy — RESOLVED
Was: no-ops.
Now: `noapi/Gpu.zig:184` — `bufferCreate` delegates to `gpuMalloc(desc.size, 64, .gpu)`; `bufferDestroy` delegates to `gpuFree`.

### 3. Gpu.drawTriangles — RESOLVED
Was: ignored args, did nothing.
Now: deleted; no match in `noapi/`; indexed draws go through `CommandBuffer.draw`/`drawIndexed`.

### 4. DescriptorPool alloc* — RESOLVED
Was: all `alloc*` returned 0.
Now: `noapi/DescriptorPool.zig:16` — per-type freelists plus `texture/texture_rw/sampler_count` counters; `alloc*` pops freelist else bumps counter and writes heap descriptors; `free*`/`freeAll` recycle.

### 5. Gpu.gpuHostToDevicePointer — RESOLVED
Was: ignored args, returned zeroed `GpuPtr`.
Now: `noapi/Gpu.zig:290` forwards to `noapi/VkBackend.zig:4640`, which scans `allocs` for the containing range and returns `cpu` plus BDA `gpu_addr + offset`; identity maps only on miss.

### 6. Gpu.zig duplicate type re-exports — RESOLVED
Was: ~40 `pub const X = @import(...)` lines duplicated `root.zig`.
Now: `noapi/Gpu.zig:298` tail holds only `FrameSchedule`/`FrameResult`/`PresentInfo`/`PresentFeedback` plus tests; public re-exports live in `noapi/root.zig`.

## Runtime Checks and Limitations

- `zig-gate` passes format, build, tests, AST, ziglint, and zlint checks.
- `zwanzig --threads 4 noapi/[A-Z]*.zig noapi/root.zig` reports 15 findings, down from 30. Removed: 12 dead `@This()` aliases, two texture-heap unwraps, and the `L` variable.
- The 15 remaining zwanzig findings are not applicable: 4 public API module names and 9 Vulkan/Tracy unwraps with non-null contracts.
- The other 2 are a called method and a false ownership warning. zwanzig still exits 1.
- Its AST walker warns that the 125-statement backend block exceeds its 64-statement analysis limit.
- After the refactor, `zig build 2_textures` created and resized the swapchain, then reported FPS on the NVIDIA GeForce GTX 1660 Ti.
- Six advisory texture-index findings have zero-ID and bounds guards.
- `zig build submission-lifecycle` passes in Debug, ReleaseFast, and without Tracy on the NVIDIA GeForce GTX 1660 Ti.
- `zig build presentation-feedback -Dpresentation-mode=selected` returned an EXT timestamp.
- `zig build presentation-feedback -Dpresentation-mode=google` returned `GooglePresentTimingUnsupported` on this device.
- With `SDL_VIDEODRIVER=wayland,x11`, all seven examples created and resized swapchains, then reported FPS. The two-window test app created both surfaces.
- SDL now chooses the video driver. The app no longer sets hints that fail when the environment has priority.
- To recheck SDL startup, run `SDL_VIDEODRIVER=wayland,x11 zig build 1_triangle`; wait for `FPS:`, then close the window.
- Desktop capture was unavailable; these checks do not verify pixels. Other GPUs and window systems remain untested.
- Instrumented library tests cover 365/3109 project lines (11.7%) and 222/1805 blocks (12.3%). GPU smoke checks are separate and not included.

## Timing Backport Status
Ported from `lxrmvysx/vendor` pin `f11603da`:
- `TimestampQuerySet` (`noapi/TimestampQuerySet.zig`): `TimestampStage`, `TimestampInfo` (`mask`/`spanTicks`), `validateQueryRange`; `Gpu.timestampInfo/timestampQuerySetCreate/timestampQuerySetDestroy/timestampQuerySetRead`; `CommandBuffer.timestampReset/timestampWrite` with range checks; `VkBackend` query-pool create/read/reset/write with `TimestampQueriesUnsupported` guard.
- Present feedback (`noapi/Surface.zig:105`, `noapi/VkBackend.zig:2281`): `pollPresentFeedback` writes into caller storage, never allocates, returns `OutputTooSmall` before it consumes a record; EXT/GOOGLE timing backends behind a 64-record bounded scratch drain.
- `deviceIdentity` (`noapi/Gpu.zig:44`, `noapi/VkBackend.zig:3360`): name, vendor/device id, driver string from the selected physical device.
- `queueSubmitWaitSignal` (`noapi/Gpu.zig:238`, `noapi/Queue.zig:34`, `noapi/VkBackend.zig:2139`): timeline wait/signal submit path alongside `queueSubmit`.
- Strict submit: `Queue.submit/submitSignal/submitWaitSignal` return early on zero command buffers; all submit paths copy handles through a 64-slot `copyCommandBufferHandles` that rejects oversize lists with `TooManyCommandBuffers`.

## Changelog (Wave 1)
- Strict submit: empty-submit early return on `Queue` paths; 64-handle cap enforced in `Gpu` and `Queue` (`TooManyCommandBuffers`).
- Index format: `CommandBuffer.IndexFormat` carries Vulkan values (`u16=0`, `u32=1`, `u8=1000265000`, `none=1000165000`); threaded through `drawIndexed`/`drawIndexedIndirect`/`drawIndexedIndirectMulti`/`bindIndexBuffer` into `VkBackend.cmdBindIndexBuffer` via `@enumFromInt`.
- `commandsEnd` removed: no `commandsEnd` remains in `Gpu`/`Queue`/`Surface`/`VkBackend`; `commandsBegin` yields the handle and submission closes it via `queueSubmit`; examples follow begin-record-submit only.

## Build Config
- `use_llvm = true` on all 8 executables
- `tracy_impl` module conditional on `-Denable-tracy`
- SDL3, noapi, tracy modules on all exes
- Tracy C++ client force-built at ReleaseFast (Debug → ReleaseFast workaround)
