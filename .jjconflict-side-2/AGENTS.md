# noapi

`noapi` is an experimental Zig `0.16.0` Vulkan access library (`0.0.0`) with SDL3 window integration. `noapi/root.zig` re-exports the public API. `Gpu.zig`, `Surface.zig`, and `CommandBuffer.zig` delegate Vulkan work to `VkBackend.zig`. `examples/` has seven applications; `test/main.zig` installs as `noapi-test`. `shaders/` has GLSL/Slang sources and checked-in SPIR-V. `build.zig.zon` pins SDL3 and Tracy.

## Contracts

- Keep the public API free of Vulkan calls. `VkBackend.zig` owns device, resource, command, and presentation work.
- Keep shader objects, dynamic rendering, descriptor buffers, buffer device addresses, and timeline semaphores in the Vulkan baseline.
- Use `Gpu.Options` for `std.Io`, allocator, frame count, validation, and diagnostics setup. Use `SurfaceOptions` for extent and presentation mode.
- Preserve `PresentMode` choices `fifo`, `mailbox`, `immediate`, and `fifo_relaxed`. `LoadOp` is `load=0`, `clear=1`, `dont_care=2`; `StoreOp` is `store=0`, `dont_care=1`.
- Generate `noapi/vk.zig` from the Khronos registry with `vulkan-zig`; do not edit it by hand.
- Build examples with the LLVM backend. Tracy is on by default.
- Match `~/Projects/github-leotmp-no_gfx_api` semantics unless a documented reason requires a difference. Compare `~/projects/codeberg-Games-by-Mason-mr_gpu`, Sokol, and GPUI for design alternatives.

## Commands

Repository root:

- `zig build` builds and installs `noapi-test` and all seven examples.
- `zig build run -- <args>` runs `noapi-test`.
- `zig build 1_triangle -- <args>` runs the triangle example; other numbered examples have matching steps.
- `zig build test` runs library tests.
- `zig build -Denable-tracy=false` builds without Tracy.
- `glslangValidator -V shaders/triangle.vert -o shaders/triangle_vert.spv` recompiles the triangle vertex shader.
- `gate` runs the configured checks in the devenv shell.

## Local workflow

- Declare libraries, headers, runtime dependencies, and tools in `devenv.nix`; do not install them imperatively on NixOS.
- Use direnv/devenv. Run `direnv allow` after environment changes, or use `devenv shell` for a one-off shell.
- Use `jj` for repository mutations, not Git mutation commands. Keep durable design and experiment notes under `docs/`.
