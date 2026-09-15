# noapi

`noapi` is a Zig 0.16.0 Vulkan library with SDL3 window integration, seven runnable examples, and an installed `noapi-test` application.

## Architecture and constraints

- `noapi/root.zig` re-exports every public API type. The main API is in `Gpu.zig`, `Surface.zig`, and `CommandBuffer.zig`. Public API types delegate Vulkan work to `noapi/VkBackend.zig`.
- Keep the Vulkan baseline: shader objects, dynamic rendering, descriptor buffers, buffer device addresses, and timeline semaphores.
- `noapi/vk.zig` contains bindings generated from the Khronos registry by `vulkan-zig`. Regenerate it; do not edit it by hand.
- `Gpu.Options` carries `std.Io`, the allocator, frame count, validation, and diagnostics. `SurfaceOptions` carries extent and presentation mode.
- Preserve `PresentMode` mappings for `fifo`, `mailbox`, `immediate`, and `fifo_relaxed`. `LoadOp` values are `load = 0`, `clear = 1`, `dont_care = 2`; `StoreOp` values are `store = 0`, `dont_care = 1`.
- `examples/` contains the applications and `examples/common.zig`. `test/main.zig` is the `noapi-test` application. `shaders/` contains sources and checked-in SPIR-V. Build example executables with the LLVM backend; Tracy is on by default.

## Commands

Run from the repository root:

- `zig build`: build and install `noapi-test` and all seven examples.
- `zig build run -- <args>`: run `noapi-test`.
- `zig build 1_triangle -- <args>`: run the triangle example. Other numbered examples have matching steps.
- `zig build test`: run library tests.
- `zig build -Denable-tracy=false`: build without Tracy.
- `glslangValidator -V shaders/triangle.vert -o shaders/triangle_vert.spv`: recompile this GLSL shader.
- `gate` in the devenv shell: run configured checks.

## References and workflow

- Match `~/Projects/github-leotmp-no_gfx_api` semantics unless a documented reason requires a difference. Compare `~/projects/codeberg-Games-by-Mason-mr_gpu`, Sokol, and GPUI for API design.
- On NixOS, declare dependencies and tools in `devenv.nix`; do not install them imperatively. Use direnv/devenv. Run `direnv allow` after environment changes or `devenv shell` for a one-off shell.
- Put durable design and experiment notes under `docs/`. Use `jj` for repository mutations, not Git mutation commands.
