# noapi

A Vulkan rendering library for Zig, with SDL3 window integration. It exposes GPU
memory, command recording, bindless descriptors, textures, synchronization, GPU
timestamps, and presentation feedback.

Experimental. The API can change.

## Requirements

- Zig 0.17.0 and a C/C++ toolchain environment.
- A Vulkan 1.4 driver with shader objects, dynamic rendering, descriptor buffers,
  buffer device addresses, and timeline semaphores.
- A Vulkan loader and validation layers. The supplied applications enable validation.
- A Wayland session for the supplied applications, which select SDL's Wayland driver.
- Linux development libraries for SDL3, including Wayland, X11, ALSA, udev,
  libxkbcommon, libdecor, and libusb. SDL3 is built from its pinned dependency.

`devenv.nix` supplies development libraries, shader compilers, and profiling tools.
Tracy profiling is enabled by default; use `-Denable-tracy=false` to disable it.

## Build and test

Run commands from the repository root. Applications load files from `shaders/`
relative to the current directory.

```sh
zig build
zig build test
zig build docs
zig build run
zig build 1_triangle
zig build -Denable-tracy=false
```

The default build installs `noapi-test` and all seven examples. Numbered run steps:

| Step | Example |
| --- | --- |
| `1_triangle` | Triangle without vertex buffers |
| `2_textures` | 2D textures |
| `3_3D` | 3D cube and camera |
| `4_textures_advanced` | Volume cloud rendering |
| `5_indirect_triangles` | Indirect drawing |
| `6_compute_shaders` | Compute and graphics |
| `7_deferred_async_load` | Deferred rendering and asynchronous asset loading |

`submission-lifecycle` runs an offscreen GPU submission check.
`presentation-feedback` checks compositor timing; select its timing backend with
`-Dpresentation-mode=selected` or `-Dpresentation-mode=google`. These checks require
a suitable Vulkan device; presentation feedback also requires compositor support.

## Use as a dependency

```sh
zig fetch --save=noapi git+https://github.com/CoffeeImpliesCode/noapi
```

In `build.zig`, import the `noapi` module:

```zig
const noapi = b.dependency("noapi", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("noapi", noapi.module("noapi"));
```

`Gpu.init` takes an allocator, `std.Io`, and Vulkan loader callbacks. Create a
`Surface` from the platform's Vulkan surface. See `examples/common.zig` for SDL3
initialization and `examples/1_triangle/main.zig` for command recording and rendering.

## Shaders

SPIR-V and `env.ppm` are runtime assets. Shader compilers are only needed when
changing shader sources. For GLSL, select the stage from the source extension:

```sh
glslangValidator -V --target-env vulkan1.3 shaders/triangle.vert -o shaders/triangle_vert.spv
```

Slang sources use `slangc`; their entry points are declared in the source. Match
the output filename to the application's shader path. Keep generated SPIR-V with
its source when changing a runtime shader.

## Layout

- `noapi/`: public API, Vulkan backend, and generated Vulkan bindings.
- `examples/`: seven applications and shared platform helpers.
- `test/main.zig`: interactive test application and GPU checks.
- `shaders/`: shader sources, SPIR-V, and the environment-map image.

## License

No license is specified in this repository.
