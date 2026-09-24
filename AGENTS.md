# noapi

Experimental Zig 0.16.0 Vulkan library. `noapi/root.zig` re-exports the public API. `Gpu.zig`, `Surface.zig`, and `CommandBuffer.zig` define its interface. `VkBackend.zig` owns Vulkan device, resource, command, and presentation work. SDL3 supplies windows. `build.zig` defines the module, tests, `noapi-test`, and seven examples. `build.zig.zon` pins SDL3 and Tracy.

## Contracts

- Keep the public API separate from Vulkan. Public types delegate backend work to `VkBackend.zig`; re-export each public type from `noapi/root.zig`.
- Keep shader objects, dynamic rendering, descriptor buffers, buffer device addresses, and timeline semaphores in the Vulkan baseline.
- Use `Gpu.Options` for `std.Io`, allocator, frame count, validation, and diagnostics. Use `SurfaceOptions` for extent and presentation mode.
- Preserve `LoadOp`: `load = 0`, `clear = 1`, `dont_care = 2`; `StoreOp`: `store = 0`, `dont_care = 1`. Preserve `PresentMode`: `fifo`, `mailbox`, `immediate`, `fifo_relaxed`.
- Do not edit generated `noapi/vk.zig`. Regenerate it with `vulkan-zig` from the Khronos registry.
- Build example executables with the LLVM backend. Tracy is on by default.
- Use `~/Projects/github-leotmp-no_gfx_api` as the primary API semantics reference unless a documented reason requires a difference.

## Commands and environment

Run from the repository root:

- `zig build`: build and install `noapi-test` and seven examples.
- `zig build run -- <args>`: run `noapi-test`.
- `zig build 1_triangle -- <args>`: run the triangle example. Other numbered examples have matching steps.
- `zig build test`: run library tests.
- `zig build -Denable-tracy=false`: disable Tracy.
- `glslangValidator -V shaders/triangle.vert -o shaders/triangle_vert.spv`: recompile this GLSL shader.
- `gate`: run configured checks in the devenv shell.

On NixOS, declare dependencies and tools in `devenv.nix`, not imperative system installs. Use direnv/devenv; run `direnv allow` after environment changes or `devenv shell` for a one-off shell. Use `jj`, not Git mutation commands. Put durable project design notes in `docs/`.
