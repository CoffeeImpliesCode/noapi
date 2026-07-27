# noapi

`noapi` is an experimental Zig `0.16.0` Vulkan access library at version
`0.0.0`. It provides a small public graphics API, a Vulkan backend, tests,
shader assets, and seven runnable examples. SDL3 supplies window integration.

## Repository outline

- `noapi/root.zig` is the public module and re-exports the API types.
- `noapi/Gpu.zig`, `Surface.zig`, and `CommandBuffer.zig` form the main API.
- `noapi/VkBackend.zig` owns Vulkan device, resource, command, and presentation work.
- `noapi/Texture.zig`, `Shader.zig`, `GpuPtr.zig`, and the state files define
  resource handles and command data.
- `noapi/vk.zig` is generated from the Khronos registry by `vulkan-zig`.
- `examples/` contains seven applications and `examples/common.zig`.
- `test/main.zig` is the installed `noapi-test` application.
- `shaders/` contains GLSL or Slang sources and checked-in SPIR-V files.
- `build.zig` defines the module, application artifacts, example steps, and tests.
- `build.zig.zon` pins SDL3 and Tracy. `devenv.nix` supplies Vulkan and shader tools.

## Local contracts

- Keep the public API separate from Vulkan. API types delegate backend work to
  `VkBackend`.
- Re-export each public type from `noapi/root.zig`.
- Keep the current Vulkan baseline: shader objects, dynamic rendering,
  descriptor buffers, buffer device addresses, and timeline semaphores.
- Use `Gpu.Options` for context setup. It carries `std.Io`, the allocator,
  frame count, validation, and diagnostics options.
- Use `SurfaceOptions` for extent and presentation mode.
- Keep `PresentMode` values mapped to `fifo`, `mailbox`, `immediate`, and
  `fifo_relaxed`.
- Keep `LoadOp` values `load = 0`, `clear = 1`, and `dont_care = 2`.
  Keep `StoreOp` values `store = 0` and `dont_care = 1`.
- Do not hand-edit `noapi/vk.zig`. Regenerate the Vulkan bindings instead.
- Build example executables with the LLVM backend. Tracy is enabled by default.
- Use `jj` for repository mutations. Do not use Git mutation commands.

## Design references

- Treat `~/Projects/github-leotmp-no_gfx_api` as the primary API reference.
  Match its semantics unless a documented reason requires a difference.
- Compare `~/projects/codeberg-Games-by-Mason-mr_gpu`, Sokol, and GPUI for
  graphics API design.

## Commands

Run these commands from the repository root:

- `zig build` builds and installs `noapi-test` and all seven examples.
- `zig build run -- <args>` runs `noapi-test`.
- `zig build 1_triangle -- <args>` runs the triangle example.
  The other numbered example directories have matching build steps.
- `zig build test` runs the library tests.
- `zig build -Denable-tracy=false` builds without Tracy instrumentation.
- `glslangValidator -V shaders/triangle.vert -o shaders/triangle_vert.spv`
  recompiles one GLSL shader.
- In the devenv shell, `gate` runs the configured project checks.

## NixOS, Development Environment & Shared Notes

- This host runs NixOS. Never install system or development libraries imperatively.
  Declare dependencies, headers, runtime libraries, and tools in `devenv.nix`.
- Use the repository's direnv/devenv environment. Run `direnv allow` after
  environment changes. Use `devenv shell` for one-off shells.
- Put durable architecture, design, protocol, and experiment notes under `docs/`.
- Put cross-project or private agent handoff notes in `~/.agents/agent-notes/`.
  Never commit these notes.
