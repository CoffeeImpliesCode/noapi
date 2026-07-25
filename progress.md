# API Issue Fix Plan

Build status: `zig build` exits 0.

## Issues

### 1. GpuArena.create — unusable (P0)

`GpuArena.gpuMalloc` (no-arg, standalone) calls `gpuMalloc(size, @alignOf(u64), .default)` which hits the stub that returns `BackendError`.

**Fix**: `GpuArena` needs a `*Gpu` reference to delegate allocation. Change `create(size)` to `create(gpu: *Gpu, size: usize)`, call `gpu.gpuMalloc`.

**File**: `noapi/GpuArena.zig`

### 2. Gpu.bufferCreate/bufferDestroy — broken lifecycle (P0)

`bufferCreate` calls `gpuMalloc` but sets `.handle = .null_handle` (never stores the actual vk.Buffer handle). `bufferDestroy` is a total no-op — leaks the allocation. The test avoids this by using raw `gpuMalloc`/`gpuFree` directly.

**Fix**: Wire `bufferCreate` through `VkBackend.bufferCreate` (which doesn't exist yet). OR remove `Buffer` struct + methods since the codebase uses `GpuPtr`+`gpuMalloc` instead (the no_gfx_api pattern). The latter is cleaner: `Buffer` is dead code.

**File**: `noapi/Gpu.zig` lines 107-114

### 3. Gpu.gpuHostToDevicePointer — wrong behavior (P1)

Returns `GpuPtr{}` with all zeros, ignoring args. Should translate a CPU pointer to a GPU address. The `GpuPtr` already caches this in its `.gpu` field from `gpuMalloc`, but for arbitrary CPU pointers this needs the BDA extension.

**Fix**: Since noapi uses BDA, `gpuHostToDevicePointer` can return the cpu address as the gpu address (identity mapping on UMA) or just return the pointer cast to u64. Currently unused in test. Simplest: implement as `return GpuPtr{ .cpu = cpu_ptr, .gpu = @intFromPtr(cpu_ptr) }`.

**File**: `noapi/Gpu.zig` lines 166-170

### 4. Gpu.drawTriangles — no-op (P1)

All args ignored, does nothing. This is a vestige of the dvui single-draw-call pattern, not the no_gfx_api push-constant design that the rest of the API follows. The test uses `CommandBuffer.draw()` instead.

**Fix**: Wire to a proper indexed-triangle draw via the backend. Uses `cmdSetShaders`, push constants, index buffer, draw. OR delete it as dead code. Keeping it but making it work is better API hygiene.

**File**: `noapi/Gpu.zig` lines 151-158

### 5. DescriptorPool alloc* — return 0 (P1)

`allocTexture`/`allocTextureRw`/`allocSampler` all `_ = self; return 0;`. Won't produce valid descriptors at runtime.

**Fix**: Implement freelist tracking. Use `next_texture`/`next_texture_rw`/`next_sampler` counters and return the current index, incrementing after. Since descriptor heap uses descriptor_buffer-style opaque u64, the index IS the descriptor for a linear heap. This is correct if the heap is a flat array and slots are allocated sequentially.

**File**: `noapi/DescriptorPool.zig`

### 6. Gpu.zig duplicate type re-exports (P2)

Bottom of `Gpu.zig` has ~40 `pub const TextureHandle = @import(...)` etc. These duplicate what `root.zig` already exports. Harmless but noisy.

**Fix**: Remove the duplicate `pub const` block from `Gpu.zig` (lines 203-246). All types are available from `root.zig`.

**File**: `noapi/Gpu.zig`

## Execution Order

1. `Gpu.zig`: remove duplicate re-exports (trivial, no risk)
2. `DescriptorPool.zig`: fix alloc* stubs (trivial)
3. `Gpu.zig`: fix `gpuHostToDevicePointer` (trivial)
4. `GpuArena.zig`: fix `create` to take `*Gpu` (moderate)
5. `Gpu.zig`: fix `bufferCreate`/`bufferDestroy` (moderate)
6. `Gpu.zig`: fix `drawTriangles` (moderate)
7. `zig build` after each to verify
