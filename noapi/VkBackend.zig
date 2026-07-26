//! VkBackend — Vulkan 1.4 backend for noapi.
//! Multi-window: each window has its own surface + swapchain, device + queue shared.

const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vk);
const vk = @import("vk.zig");
const Extent2D = @import("Extent2D.zig");
const DeviceLimits = @import("DeviceLimits.zig");
const Stage = @import("Barrier.zig").Stage;
const Hazard = @import("Barrier.zig").Hazard;
const DepthState = @import("DepthState.zig");
const RasterState = @import("RasterState.zig");
const BlendState = @import("BlendState.zig");
const Viewport = @import("Viewport.zig");
const Scissor = @import("Viewport.zig").Scissor;
const PushData = @import("CommandBuffer.zig").PushData;
const IndexFormat = @import("CommandBuffer.zig").IndexFormat;
const Rendering = @import("Rendering.zig");
const MemoryType = @import("GpuError.zig").MemoryType;
const GpuPtr = @import("GpuPtr.zig");
const VertexBinding = @import("VertexInput.zig").VertexBinding;
const VertexAttribute = @import("VertexInput.zig").VertexAttribute;
const Texture = @import("Texture.zig");
const TextureDesc = Texture.TextureDesc;
const TextureViewDesc = Texture.TextureViewDesc;
const SamplerDesc = Texture.SamplerDesc;
const TextureFormat = Texture.TextureFormat;
const TextureType = Texture.TextureType;
const TextureUsage = Texture.TextureUsage;
const TextureRegion = Texture.TextureRegion;
const BlitRect = Texture.BlitRect;
const Filter = Texture.Filter;
const FrameSchedule = @import("Gpu.zig").FrameSchedule;
const FrameResult = @import("Gpu.zig").FrameResult;
const PresentInfo = @import("Gpu.zig").PresentInfo;

pub const VkBackend = @This();

// Swapchain recreation strategy: when false, uses deviceWaitIdle (slow but
// safe everywhere). When true, uses VK_EXT_swapchain_maintenance1 fence
// (~10x faster, requires extension + driver support).
const use_swapchain_maintenance1 = true;

// Opaque handle types that the backend uses for resources
pub const CommandBufferHandle = vk.CommandBuffer;
pub const ShaderHandle = vk.ShaderEXT;
pub const SemaphoreHandle = vk.Semaphore;
pub const BufferHandle = vk.Buffer;
pub const QueueHandle = vk.Queue;
pub const TextureHandle = @import("TextureHandle.zig");

pub const max_textures = 65536;
pub const max_samplers = 256;

allocator: Allocator = undefined,
b: vk.BaseWrapper = undefined,
vki: vk.InstanceWrapper = undefined,
vkd: vk.DeviceWrapper = undefined,
instance: vk.InstanceProxy = undefined,
debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
physical_device: vk.PhysicalDevice = undefined,
device: vk.DeviceProxy = undefined,
queue: vk.QueueProxy = undefined,
queue_family_index: u32 = undefined,
queue_sem: vk.Semaphore = undefined,
offscreen_cmd_pool: vk.CommandPool = .null_handle,
free_cmd_bufs: std.ArrayList(vk.CommandBuffer) = undefined,
submitted_work: std.ArrayList(SubmittedWork) = undefined,
queue_counter: u64 = 0,
queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
io: std.Io,

// Shared descriptor set layouts (no_gfx_api pattern: 3 base sets + optional raytracing)
desc_layouts: [3]vk.DescriptorSetLayout = undefined,
pipeline_layout_graphics: vk.PipelineLayout = undefined,
pipeline_layout_compute: vk.PipelineLayout = undefined,

    frames_in_flight: u32 = 2,
    windows: std.ArrayListUnmanaged(Window) = std.ArrayListUnmanaged(Window).empty,

// Buffer resource pool (no_gfx_api pattern: pooled allocs with handles)
allocs: std.ArrayListUnmanaged(AllocInfo) = .empty,
// Texture pool (index = u32 handle, .id field)
textures: std.ArrayListUnmanaged(TextureInfo) = .empty,
// Descriptor heap pool
desc_heaps: std.ArrayListUnmanaged(DescHeapInfo) = .empty,

// Cache: texture view descriptors (key = (texture_id << 32) | view_desc_hash)
texture_view_cache: std.AutoHashMap(u64, vk.ImageView) = undefined,
// Cache: sampler descriptors (key = sampler_desc_hash)
sampler_cache: std.AutoHashMap(u64, vk.Sampler) = undefined,
// Device limits queried at init from VkPhysicalDeviceProperties
device_limits: DeviceLimits = .{},
// Memory properties cached at init from vkGetPhysicalDeviceMemoryProperties
mem_props: vk.PhysicalDeviceMemoryProperties = undefined,

// Deferred free list — avoids deviceWaitIdle per individual free
pending_free: std.ArrayList(PendingFree) = .empty,

// Depth attachment state for reverse barrier in cmdEndRendering
last_depth_image: vk.Image = .null_handle,
last_depth_format: vk.Format = .undefined,

    const TextureInfo = struct {
        valid: bool = true,
        image: vk.Image,
        default_view: vk.ImageView,
        memory: vk.DeviceMemory = .null_handle,
        format: vk.Format,
        width: u32 = 0,
        height: u32 = 0,
        depth: u32 = 1,
        mip_levels: u32 = 1,
    };

pub const DescHeapInfo = struct {
    valid: bool = true,
    pool: vk.DescriptorPool,
    sets: [3]vk.DescriptorSet, // textures, textures_rw, samplers
};

pub const Window = struct {
    valid: bool = true,
    surface: vk.SurfaceKHR = .null_handle,
    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_format: vk.Format = .b8g8r8a8_srgb,
    extent: Extent2D = .{}, // actual swapchain image extent
    requested_extent: Extent2D = .{}, // pending resize request
    images: std.ArrayListUnmanaged(vk.Image) = .empty,
    views: std.ArrayListUnmanaged(vk.ImageView) = .empty,
    present_sems: std.ArrayListUnmanaged(vk.Semaphore) = .empty,
    frames_in_flight: u32 = 2,
    cmd_pools: std.ArrayListUnmanaged(vk.CommandPool) = .empty,
    cmd_buffers: std.ArrayListUnmanaged(vk.CommandBufferProxy) = .empty,
    cmd_pool_ready: std.ArrayListUnmanaged(vk.Fence) = .empty,
    present_done_fences: std.ArrayListUnmanaged(vk.Fence) = if (use_swapchain_maintenance1) .empty else undefined,
    frame_index: u32 = 0,
    image_index: u32 = 0,
    needs_resize: bool = false,
    resize_throttle: u32 = 0,
    retired_swapchain: vk.SwapchainKHR = .null_handle,
    // Per-frame pending wait/signal semaphores (submitted with cmd buf in endFrame)
    wait_sems: [2]std.ArrayListUnmanaged(vk.Semaphore) = .{ .empty, .empty },
    wait_values: [2]std.ArrayListUnmanaged(u64) = .{ .empty, .empty },
    signal_sems: [2]std.ArrayListUnmanaged(vk.Semaphore) = .{ .empty, .empty },
    signal_values: [2]std.ArrayListUnmanaged(u64) = .{ .empty, .empty },
};

const SubmittedWork = struct {
    cmds: []const vk.CommandBuffer,
    fence: vk.Fence,
};

pub const Options = struct {
    app_name: [:0]const u8 = "noapi",
    validation: bool = false,
    frames_in_flight: u32 = 2,
    loader: Loader = .{},
    io: std.Io,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub const Loader = struct {
        get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null,
        get_instance_extensions: ?*const fn () []const [*:0]const u8 = null,
    };
};

const DeviceFeatures = struct {
    vk10: vk.PhysicalDeviceFeatures2 = .{ .features = .{
        .shader_int_64 = .true,
        .sampler_anisotropy = .true,
    } },
    vk11: vk.PhysicalDeviceVulkan11Features = .{ .shader_draw_parameters = .true },
    vk12: vk.PhysicalDeviceVulkan12Features = .{},
    vk13: vk.PhysicalDeviceVulkan13Features = .{},
    shader_object: vk.PhysicalDeviceShaderObjectFeaturesEXT = .{},
    descriptor_buffer: vk.PhysicalDeviceDescriptorBufferFeaturesEXT = .{},
    swapchain_maint1: vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT = .{},

    fn init(self: *DeviceFeatures) void {
        self.vk10.features.shader_int_64 = .true;
        self.vk10.features.sampler_anisotropy = .true;
        self.vk11.shader_draw_parameters = .true;
        self.vk11.p_next = @constCast(&self.vk12);
        self.vk10.p_next = @constCast(&self.vk11);
        self.vk12 = .{
            .runtime_descriptor_array = .true,
            .shader_sampled_image_array_non_uniform_indexing = .true,
            .descriptor_binding_sampled_image_update_after_bind = .true,
            .descriptor_binding_storage_image_update_after_bind = .true,
            .descriptor_binding_partially_bound = .true,
            .timeline_semaphore = .true,
            .buffer_device_address = .true,
            .scalar_block_layout = .true,
            .draw_indirect_count = .true,
            .p_next = @constCast(&self.descriptor_buffer),
        };
        self.descriptor_buffer = .{ .descriptor_buffer = .true, .p_next = @constCast(&self.shader_object) };
        self.shader_object = .{ .shader_object = .true, .p_next = @constCast(&self.vk13) };
        self.vk13 = .{
            .dynamic_rendering = .true,
            .synchronization_2 = .true,
            .p_next = null,
        };
        if (use_swapchain_maintenance1) {
            self.swapchain_maint1 = .{ .swapchain_maintenance_1 = .true, .p_next = @constCast(&self.vk13) };
            self.shader_object.p_next = @constCast(&self.swapchain_maint1);
        }
    }
};

const AllocInfo = extern struct {
    buf: vk.Buffer,
    memory: vk.DeviceMemory,
    gpu_addr: u64,
    cpu: ?[*]u8,
    size: u64,
};

/// Resources pending deferred destruction. Pushed by gpuFree/textureDestroy/descHeapDestroy,
/// drained by flushPendingFrees which calls deviceWaitIdle once then destroys all.
const PendingFree = union(enum) {
    texture: struct {
        image: vk.Image,
        view: vk.ImageView,
        memory: vk.DeviceMemory,
    },
    buffer: struct {
        buf: vk.Buffer,
        memory: vk.DeviceMemory,
        cpu: ?[*]u8,
    },
    desc_heap: struct {
        pool: vk.DescriptorPool,
        sets: [3]vk.DescriptorSet,
    },
};

const required_device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
    "VK_EXT_shader_object",
    "VK_EXT_descriptor_buffer",
    "VK_KHR_buffer_device_address",
} ++ if (use_swapchain_maintenance1) [_][*:0]const u8{
    "VK_EXT_swapchain_maintenance1",
} else [_][*:0]const u8{};

// Push constant layouts (matches no_gfx_api Graphics_Shader_Push_Constants)
const GraphicsPushConstants = extern struct {
    vert_data: u64,
    frag_data: u64,
    indirect_data: u64,
};
const ComputePushConstants = extern struct {
    compute_data: u64,
};

pub fn init(options: Options) !VkBackend {
    const alloc = options.allocator;
    var self = VkBackend{ .allocator = alloc, .io = options.io };
    self.texture_view_cache = std.AutoHashMap(u64, vk.ImageView).init(alloc);
    self.sampler_cache = std.AutoHashMap(u64, vk.Sampler).init(alloc);

    const get_proc_addr = options.loader.get_instance_proc_addr orelse return error.BackendError;
    self.b = vk.BaseWrapper.load(get_proc_addr);
    log.info("Base wrapper loaded", .{});

    const app_info = vk.ApplicationInfo{
        .p_application_name = if (options.app_name.len > 0) options.app_name else "noapi",
        .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .p_engine_name = "noapi",
        .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .api_version = @bitCast(vk.makeApiVersion(0, 1, 4, 0)),
    };

    var enabled_extensions = std.ArrayList([*:0]const u8).empty;
    defer enabled_extensions.deinit(alloc);

    if (options.loader.get_instance_extensions) |get_exts| {
        try enabled_extensions.appendSlice(alloc, get_exts());
    }
    if (builtin.os.tag == .linux) {
        try enabled_extensions.append(alloc, "VK_KHR_wayland_surface");
        try enabled_extensions.append(alloc, "VK_KHR_xlib_surface");
    }
    try enabled_extensions.append(alloc, "VK_KHR_surface");
    if (options.validation) try enabled_extensions.append(alloc, "VK_EXT_debug_utils");
    if (use_swapchain_maintenance1) {
        try enabled_extensions.append(alloc, "VK_KHR_get_surface_capabilities2");
        try enabled_extensions.append(alloc, "VK_EXT_surface_maintenance1");
    }

    const enabled_layers: []const [*:0]const u8 = blk: {
        if (!options.validation) break :blk &.{};
        const layer_props = try self.b.enumerateInstanceLayerPropertiesAlloc(alloc);
        defer alloc.free(layer_props);
        for (layer_props) |lp| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&lp.layer_name)), 0);
            if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) break :blk &.{"VK_LAYER_KHRONOS_validation"};
        }
        log.warn("VK_LAYER_KHRONOS_validation not found", .{});
        break :blk &.{};
    };

    var debug_messenger_ci = vk.DebugUtilsMessengerCreateInfoEXT{
        .pfn_user_callback = @ptrCast(&debugCallback),
        .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
        .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
    };

    const instance_ci = vk.InstanceCreateInfo{
        .p_application_info = &app_info,
        .pp_enabled_layer_names = enabled_layers.ptr,
        .enabled_layer_count = @intCast(enabled_layers.len),
        .pp_enabled_extension_names = enabled_extensions.items.ptr,
        .enabled_extension_count = @intCast(enabled_extensions.items.len),
        .p_next = if (options.validation) @ptrCast(&debug_messenger_ci) else null,
    };

    const instance_handle = try self.b.createInstance(&instance_ci, null);
    self.vki = vk.InstanceWrapper.load(instance_handle, self.b.dispatch.vkGetInstanceProcAddr.?);
    self.instance = vk.InstanceProxy{ .handle = instance_handle, .wrapper = &self.vki };
    log.info("Instance created (Vulkan 1.4)", .{});

    if (options.validation) {
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&debug_messenger_ci, null);
        log.info("Debug messenger created", .{});
    }

    const devices = try self.instance.enumeratePhysicalDevicesAlloc(alloc);
    defer alloc.free(devices);
    if (devices.len == 0) return error.BackendError;

    var best_score: u32 = 0;
    var best_device: vk.PhysicalDevice = devices[0];
    for (devices) |pd| {
        const props = self.instance.getPhysicalDeviceProperties(pd);
        const score: u32 = switch (props.device_type) {
            .discrete_gpu => 1000,
            .integrated_gpu => 100,
            .virtual_gpu => 50,
            else => 10,
        };
        const qf_props = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pd, alloc);
        defer alloc.free(qf_props);
        const has_graphics = for (qf_props) |qf| {
            if (qf.queue_flags.graphics_bit) break true;
        } else false;
        if (!has_graphics) continue;
        if (score > best_score) {
            best_score = score;
            best_device = pd;
        }
    }
    self.physical_device = best_device;
    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);

    const gpu_props = self.instance.getPhysicalDeviceProperties(self.physical_device);
    log.info("GPU: {s}", .{@as([]const u8, &gpu_props.device_name)});

    // Query device limits from Vulkan
    {
        const L = gpu_props.limits;
        self.device_limits = .{
            .max_anisotropy = L.max_sampler_anisotropy,
            .max_texture_dimension_2d = L.max_image_dimension_2d,
            .max_texture_dimension_3d = L.max_image_dimension_3d,
            .max_texture_array_layers = L.max_image_array_layers,
            .max_push_constants_size = L.max_push_constants_size,
            .max_viewports = L.max_viewports,
            .max_color_attachments = L.max_color_attachments,
            .max_framebuffer_width = L.max_framebuffer_width,
            .max_framebuffer_height = L.max_framebuffer_height,
            .max_framebuffer_layers = L.max_framebuffer_layers,
            .max_compute_work_group_invocations = L.max_compute_work_group_invocations,
            .max_compute_shared_memory_size = L.max_compute_shared_memory_size,
            .min_uniform_buffer_offset_alignment = @intCast(L.min_uniform_buffer_offset_alignment),
            .min_storage_buffer_offset_alignment = @intCast(L.min_storage_buffer_offset_alignment),
            // Feature flags — all enabled by the device features struct in init
            .shader_object = true,
            .descriptor_buffer = true,
            .buffer_device_address = true,
            .dynamic_rendering = true,
            .timeline_semaphore = true,
            .descriptor_indexing = true,
        };
    }

    const qf_all = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.physical_device, alloc);
    defer alloc.free(qf_all);
    self.queue_family_index = 0;
    for (qf_all, 0..) |qf, i| {
        if (qf.queue_flags.graphics_bit) {
            self.queue_family_index = @intCast(i);
            break;
        }
    }
    log.info("Queue family: {}", .{self.queue_family_index});

    var features = DeviceFeatures{};
    features.init();

    const q_prio = [_]f32{1.0};
    const queue_ci = vk.DeviceQueueCreateInfo{
        .queue_family_index = self.queue_family_index,
        .p_queue_priorities = q_prio[0..].ptr,
        .queue_count = 1,
    };
    const device_ci = vk.DeviceCreateInfo{
        .p_next = @ptrCast(&features.vk10),
        .p_queue_create_infos = &.{queue_ci},
        .queue_create_info_count = 1,
        .pp_enabled_extension_names = &required_device_extensions,
        .enabled_extension_count = required_device_extensions.len,
    };
    const device_handle = try self.instance.createDevice(self.physical_device, &device_ci, null);
    self.vkd = vk.DeviceWrapper.load(device_handle, self.vki.dispatch.vkGetDeviceProcAddr.?);
    self.device = vk.DeviceProxy{ .handle = device_handle, .wrapper = &self.vkd };
    const q_handle = self.device.getDeviceQueue(self.queue_family_index, 0);
    self.queue = .{ .handle = q_handle, .wrapper = &self.vkd };

    log.info("Device created (shader objects + descriptor buffer + BDA)", .{});

    // Per-queue timeline semaphore for frame pacing
    self.queue_sem = try self.device.createSemaphore(
        &.{ .p_next = @constCast(&vk.SemaphoreTypeCreateInfo{
            .semaphore_type = .timeline,
            .initial_value = 0,
        }) },
        null,
    );
    log.info("Queue timeline semaphore created", .{});

    // Offscreen command pool (transient, for one-shot command buffers)
    self.offscreen_cmd_pool = try self.device.createCommandPool(&.{
        .queue_family_index = self.queue_family_index,
        .flags = .{ .transient_bit = true },
    }, null);
    log.info("Offscreen command pool created", .{});

    // Command buffer lifecycle tracking (fence-based recycling)
    self.free_cmd_bufs = .empty;
    self.submitted_work = .empty;

    // ── Descriptor set layouts (no_gfx_api pattern) ─────────
    {
        const binding_flags = vk.DescriptorBindingFlags{ .update_after_bind_bit = true, .partially_bound_bit = true };
        const flags = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .binding_count = 1,
            .p_binding_flags = @ptrCast(&binding_flags),
        };
        const binding_types = [_]vk.DescriptorType{ .sampled_image, .storage_image, .sampler };
        const binding_counts = [_]u32{ max_textures, max_textures, max_samplers };
        for (&binding_types, &binding_counts, 0..) |dtype, dcount, i| {
            const bnd = vk.DescriptorSetLayoutBinding{
                .binding = 0,
                .descriptor_type = dtype,
                .descriptor_count = dcount,
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true, .compute_bit = true },
            };
            self.desc_layouts[i] = try self.device.createDescriptorSetLayout(&.{
                .p_next = @constCast(&flags),
                .flags = .{ .update_after_bind_pool_bit = true },
                .binding_count = 1,
                .p_bindings = @ptrCast(&[_]vk.DescriptorSetLayoutBinding{bnd}),
            }, null);
        }
        log.info("Descriptor set layouts created", .{});
    }

    // ── Shared pipeline layouts (graphics + compute) ────────
    {
        const pc_range_gfx = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            .offset = 0,
            .size = @sizeOf(GraphicsPushConstants),
        };
        self.pipeline_layout_graphics = try self.device.createPipelineLayout(&.{
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&pc_range_gfx),
            .set_layout_count = 3,
            .p_set_layouts = @ptrCast(&self.desc_layouts),
        }, null);
        const pc_range_comp = vk.PushConstantRange{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            .size = @sizeOf(ComputePushConstants),
        };
        self.pipeline_layout_compute = try self.device.createPipelineLayout(&.{
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&pc_range_comp),
            .set_layout_count = 3,
            .p_set_layouts = @ptrCast(&self.desc_layouts),
        }, null);
        log.info("Pipeline layouts created", .{});
    }

    return self;
}

/// Drain the pending-free list: one deviceWaitIdle, then destroy all deferred resources.
pub fn flushPendingFrees(self: *VkBackend) void {
    if (self.pending_free.items.len == 0) return;
    {
        const zone_dwi = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi.end();
        self.device.deviceWaitIdle() catch |err| log.warn("flushPendingFrees: deviceWaitIdle failed: {}", .{err});
    }
    for (self.pending_free.items) |pf| {
        switch (pf) {
            .buffer => |b| {
                if (b.cpu != null) self.device.unmapMemory(b.memory);
                self.device.destroyBuffer(b.buf, null);
                self.device.freeMemory(b.memory, null);
            },
            .texture => |t| {
                self.device.destroyImageView(t.view, null);
                self.device.destroyImage(t.image, null);
                if (t.memory != .null_handle) self.device.freeMemory(t.memory, null);
            },
            .desc_heap => |d| {
                self.device.freeDescriptorSets(d.pool, d.sets[0..]) catch |err| log.warn("flushPendingFrees: freeDescriptorSets failed: {}", .{err});
                self.device.destroyDescriptorPool(d.pool, null);
            },
        }
    }
    self.pending_free.clearRetainingCapacity();
}

pub fn deinit(self: *VkBackend) void {
    {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const zone_dwi_d = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi_d.end();
        self.device.deviceWaitIdle() catch |err| log.warn("deinit: deviceWaitIdle failed: {}", .{err});
    }
    // Free all buffer allocations (fixes exit validation errors)
    for (self.allocs.items) |alloc| {
        if (alloc.cpu != null) self.device.unmapMemory(alloc.memory);
        self.device.destroyBuffer(alloc.buf, null);
        self.device.freeMemory(alloc.memory, null);
    }
    self.allocs.deinit(self.allocator);
    // Destroy all texture images + views (skip invalid slots)
    for (self.textures.items) |ti| {
        if (!ti.valid) continue;
        self.device.destroyImageView(ti.default_view, null);
        self.device.destroyImage(ti.image, null);
        if (ti.memory != .null_handle) self.device.freeMemory(ti.memory, null);
    }
    self.textures.deinit(self.allocator);
    // Destroy all descriptor heaps (skip invalid slots)
    for (self.desc_heaps.items) |dh| {
        if (!dh.valid) continue;
        self.device.freeDescriptorSets(dh.pool, dh.sets[0..]) catch |err| log.warn("deinit: freeDescriptorSets failed: {}", .{err});
        self.device.destroyDescriptorPool(dh.pool, null);
    }
    self.desc_heaps.deinit(self.allocator);
    self.pending_free.deinit(self.allocator);
    // Destroy cached texture views to prevent VkImageView leaks
    {
        var it = self.texture_view_cache.iterator();
        while (it.next()) |entry| {
            self.device.destroyImageView(entry.value_ptr.*, null);
        }
        self.texture_view_cache.deinit();
    }
    // Destroy cached samplers to prevent VkSampler leaks
    {
        var it = self.sampler_cache.iterator();
        while (it.next()) |entry| {
            self.device.destroySampler(entry.value_ptr.*, null);
        }
        self.sampler_cache.deinit();
    }
    for (self.windows.items) |*win| if (win.valid) destroyWindow(self, win);
    self.windows.deinit(self.allocator);
    self.device.destroyPipelineLayout(self.pipeline_layout_compute, null);
    self.device.destroyPipelineLayout(self.pipeline_layout_graphics, null);
    for (&self.desc_layouts) |*layout| self.device.destroyDescriptorSetLayout(layout.*, null);
    // Free any pending submitted work before destroying the pool.
    for (self.submitted_work.items) |work| {
        self.device.freeCommandBuffers(self.offscreen_cmd_pool, work.cmds);
        self.device.destroyFence(work.fence, null);
        self.allocator.free(work.cmds);
    }
    self.submitted_work.deinit(self.allocator);
    self.free_cmd_bufs.deinit(self.allocator);
    self.device.destroySemaphore(self.queue_sem, null);
    if (self.offscreen_cmd_pool != .null_handle)
        self.device.destroyCommandPool(self.offscreen_cmd_pool, null);
    self.device.destroyDevice(null);
    if (self.debug_messenger != .null_handle)
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
}

pub fn numWindows(self: *const VkBackend) u32 {
    return @intCast(self.windows.items.len);
}

pub fn addWindow(self: *VkBackend, surface: vk.SurfaceKHR, initial_extent: Extent2D) !u32 {
    // Find tombstone slot or append
    for (self.windows.items, 0..) |*w, i| {
        if (!w.valid) {
            log.info("addWindow: reusing tombstone slot {}", .{i});
            w.* = Window{ .surface = surface, .extent = initial_extent, .requested_extent = initial_extent, .frames_in_flight = 2 };
            try createSwapchainResources(self, w);
            try createPresentSemaphores(self, w);
            if (use_swapchain_maintenance1) {
                try w.present_done_fences.ensureTotalCapacity(self.allocator, w.frames_in_flight);
                for (0..w.frames_in_flight) |_| {
                    const fence = try self.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
                    w.present_done_fences.appendAssumeCapacity(fence);
                }
            }
            try createPerFrameResources(self, w);
            log.info("addWindow: done (slot {})", .{i});
            return @intCast(i);
        }
    }
    const idx = self.windows.items.len;
    log.info("addWindow: createSwapchainResources", .{});
    var win = Window{ .surface = surface, .extent = initial_extent, .requested_extent = initial_extent, .frames_in_flight = 2 };
    try createSwapchainResources(self, &win);
    log.info("addWindow: createPresentSemaphores", .{});
    try createPresentSemaphores(self, &win);
    if (use_swapchain_maintenance1) {
        try win.present_done_fences.ensureTotalCapacity(self.allocator, win.frames_in_flight);
        for (0..win.frames_in_flight) |_| {
            const fence = try self.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
            win.present_done_fences.appendAssumeCapacity(fence);
        }
    }
    log.info("addWindow: createPerFrameResources", .{});
    try createPerFrameResources(self, &win);
    log.info("addWindow: done (slot {})", .{idx});
    try self.windows.append(self.allocator, win);
    return @intCast(idx);
}

pub fn removeWindow(self: *VkBackend, index: u32) void {
    if (index < self.windows.items.len and self.windows.items[index].valid) {
        // Drain all pending queue operations before destroying this window's resources.
        // The other thread may have submissions referencing our semaphores/fences on the shared queue.
        self.queue_mutex.lockUncancelable(self.io);
        const zone_dwi_r = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi_r.end();
        self.device.deviceWaitIdle() catch |err| log.warn("removeWindow: deviceWaitIdle failed: {}", .{err});
        self.queue_mutex.unlock(self.io);
        destroyWindow(self, &self.windows.items[index]);
        self.windows.items[index].valid = false;
    }
}

pub fn beginFrame(self: *VkBackend, window_index: u32) !FrameSchedule {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;

        // ── Handle resize ───────────────────────────────────────────
    if (win.needs_resize) {
        const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (use_swapchain_maintenance1) {
            for (win.present_done_fences.items) |f| {
                const zone_wf_resize = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
                defer zone_wf_resize.end();
                _ = self.device.waitForFences(&[_]vk.Fence{f}, .true, std.math.maxInt(u64)) catch |err| log.warn("beginFrame: waitForFences failed: {}", .{err});
            }
        } else {
            const zone_dwi_bf = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
            defer zone_dwi_bf.end();
            self.device.deviceWaitIdle() catch |err| log.warn("beginFrame: deviceWaitIdle failed: {}", .{err});
        }
        try recreateSwapchain(self, win);
        win.needs_resize = false;
        win.resize_throttle = 2;
    }

    const acq_fence = try self.device.createFence(&.{}, null);
    defer self.device.destroyFence(acq_fence, null);

    const recreated = blk: {
        const zone_acq = tracy.Zone.begin(.{ .name = "acquireImage", .src = @src(), .color = .tomato });
        defer zone_acq.end();
        const acq = self.device.acquireNextImageKHR(win.swapchain, std.math.maxInt(u64), .null_handle, acq_fence) catch |e| {
            if (e == error.OutOfDateKHR) {
                win.needs_resize = true;
                return error.OutOfDateKHR;
            }
            return e;
        };
        win.image_index = acq.image_index;
        _ = try self.device.waitForFences(([_]vk.Fence{acq_fence})[0..], .true, std.math.maxInt(u64));
        break :blk acq.result == .suboptimal_khr;
    };

    // Wait for previous frame to finish before reusing pool/fence
    {
        const zone_wf_cmd = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
        defer zone_wf_cmd.end();
        _ = try self.device.waitForFences(win.cmd_pool_ready.items[frame..][0..1], .true, std.math.maxInt(u64));
    }
    try self.device.resetFences(win.cmd_pool_ready.items[frame..][0..1]);
    {
        const zone_rcp = tracy.Zone.begin(.{ .name = "resetCmdPool", .src = @src(), .color = .tomato });
        defer zone_rcp.end();
        _ = self.device.resetCommandPool(win.cmd_pools.items[frame], .{}) catch |err| log.warn("beginFrame: resetCommandPool failed: {}", .{err});
    }

    self.flushPendingFrees();

    // Begin command buffer and transition UNDEFINED -> GENERAL
    win.cmd_buffers.items[frame].beginCommandBuffer(&.{ .flags = .{ .one_time_submit_bit = true } }) catch |err| log.err("beginFrame: beginCommandBuffer failed: {}", .{err});
    {
        const barrier = vk.ImageMemoryBarrier2{
            .image = win.images.items[win.image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .old_layout = .undefined,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
        };
        win.cmd_buffers.items[frame].pipelineBarrier2(&vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    return .{ .next_vblank_us = 16667, .swapchain_recreated = recreated };
}

pub fn currentSwapchainImage(self: *const VkBackend, window_index: u32) TextureHandle {
    const win = &self.windows.items[window_index];
    return TextureHandle{ .tag = .swapchain, .swapchain = .{ .window_index = window_index, .image_index = win.image_index } };
}

pub fn endFrame(self: *VkBackend, window_index: u32, present: ?PresentInfo) FrameResult {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    const img_idx = win.image_index;

    // Transition GENERAL -> PRESENT_SRC_KHR
    {
        const barrier = vk.ImageMemoryBarrier2{
            .image = win.images.items[img_idx],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .old_layout = .general,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
            .dst_access_mask = .{},
        };
        win.cmd_buffers.items[frame].pipelineBarrier2(&vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    win.cmd_buffers.items[frame].endCommandBuffer() catch |err| log.err("endFrame: endCommandBuffer failed: {}", .{err});

    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);

    // Submit with timeline semaphore for GPU serialization (no_gfx_api pattern)
    const wait_val = self.queue_counter;
    const signal_val = wait_val + 1;
    const present_sem = win.present_sems.items[img_idx];

    // Build wait list: queue_sem + any user-added wait semaphores
    var wait_sems_buf: [16]vk.Semaphore = undefined;
    var wait_vals_buf: [16]u64 = undefined;
    var stage_mask_buf: [16]vk.PipelineStageFlags = undefined;
    var wc: u32 = 0;
    wait_sems_buf[wc] = self.queue_sem;
    wait_vals_buf[wc] = wait_val;
    stage_mask_buf[wc] = .{ .all_commands_bit = true };
    wc += 1;
    const wait_count = @min(win.wait_sems[frame].items.len, 16 - wc);
    for (win.wait_sems[frame].items[0..wait_count], win.wait_values[frame].items[0..wait_count], wc..) |s, v, i| {
        wait_sems_buf[i] = s;
        wait_vals_buf[i] = v;
        stage_mask_buf[i] = .{ .all_commands_bit = true };
        wc += 1;
    }

    // Build signal list: queue_sem + present_sem + any user-added signal semaphores
    var signal_sems_buf: [16]vk.Semaphore = undefined;
    var signal_vals_buf: [16]u64 = undefined;
    var sc: u32 = 0;
    signal_sems_buf[sc] = self.queue_sem;
    signal_vals_buf[sc] = signal_val;
    sc += 1;
    signal_sems_buf[sc] = present_sem;
    signal_vals_buf[sc] = 0;
    sc += 1;
    const signal_count = @min(win.signal_sems[frame].items.len, 16 - sc);
    for (win.signal_sems[frame].items[0..signal_count], win.signal_values[frame].items[0..signal_count], sc..) |s, v, i| {
        signal_sems_buf[i] = s;
        signal_vals_buf[i] = v;
        sc += 1;
    }

    const ts_info = vk.TimelineSemaphoreSubmitInfo{
        .wait_semaphore_value_count = wc,
        .p_wait_semaphore_values = &wait_vals_buf,
        .signal_semaphore_value_count = sc,
        .p_signal_semaphore_values = &signal_vals_buf,
    };
    const cb_handle = win.cmd_buffers.items[frame].handle;
    {
        const zone_qs = tracy.Zone.begin(.{ .name = "queueSubmit", .src = @src(), .color = .tomato });
        defer zone_qs.end();
        self.queue.submit(&.{vk.SubmitInfo{
            .p_next = @constCast(&ts_info),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cb_handle),
            .wait_semaphore_count = wc,
            .p_wait_semaphores = &wait_sems_buf,
            .p_wait_dst_stage_mask = &stage_mask_buf,
            .signal_semaphore_count = sc,
            .p_signal_semaphores = &signal_sems_buf,
        }}, win.cmd_pool_ready.items[frame]) catch |e| {
            log.err("endFrame: queue.submit failed: {}", .{e});
            return .{ .gpu_blocked_ns = 0 };
        };
    }
    // Clear per-frame semaphore arrays for next use
    win.wait_sems[frame].clearRetainingCapacity();
    win.wait_values[frame].clearRetainingCapacity();
    win.signal_sems[frame].clearRetainingCapacity();
    win.signal_values[frame].clearRetainingCapacity();
    self.queue_counter = signal_val;

    if (present) |p| {
        if (p.blit_to_swapchain) {
            var fence_info: if (use_swapchain_maintenance1) vk.SwapchainPresentFenceInfoEXT else void = undefined;
            const af_present = if (use_swapchain_maintenance1) blk: {
                const pfence = win.present_done_fences.items[frame];
                // Wait for this frame's previous present to complete
                const zone_wf_p = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
                defer zone_wf_p.end();
                _ = self.device.waitForFences(&[_]vk.Fence{pfence}, .true, std.math.maxInt(u64)) catch |err| log.warn("present: waitForFences failed: {}", .{err});
                self.device.resetFences(&[_]vk.Fence{pfence}) catch |err| log.warn("present: resetFences failed: {}", .{err});
                fence_info = .{ .swapchain_count = 1, .p_fences = @ptrCast(&pfence) };
                break :blk vk.PresentInfoKHR{
                    .p_next = @ptrCast(&fence_info),
                    .wait_semaphore_count = 1,
                    .p_wait_semaphores = @ptrCast(&present_sem),
                    .swapchain_count = 1,
                    .p_swapchains = @ptrCast(&win.swapchain),
                    .p_image_indices = @ptrCast(&img_idx),
                };
            } else vk.PresentInfoKHR{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&present_sem),
                .swapchain_count = 1,
                .p_swapchains = @ptrCast(&win.swapchain),
                .p_image_indices = @ptrCast(&img_idx),
            };
            const zone_present = tracy.Zone.begin(.{ .name = "queuePresent", .src = @src(), .color = .tomato });
            defer zone_present.end();
            if (self.queue.presentKHR(&af_present)) |_| {
                if (win.retired_swapchain != .null_handle) {
                    self.device.destroySwapchainKHR(win.retired_swapchain, null);
                    win.retired_swapchain = .null_handle;
                }
            } else |e| {
                    if (e == error.OutOfDateKHR) {
                        win.needs_resize = true;
                } else {
                    log.warn("endFrame: present failed: {}", .{e});
                }
            }
        }
    }

    if (win.resize_throttle > 0) win.resize_throttle -= 1;
    win.frame_index = (frame + 1) % win.frames_in_flight;
    return .{ .gpu_blocked_ns = 0 };
}
pub fn getCurrentCmdBuf(self: *VkBackend, window_index: u32) CommandBufferHandle {
    const win = &self.windows.items[window_index];
    return win.cmd_buffers.items[win.frame_index].handle;
}

pub fn waitIdle(self: *VkBackend) void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    const zone_dwi_w = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
    defer zone_dwi_w.end();
    self.device.deviceWaitIdle() catch |err| log.warn("waitIdle: deviceWaitIdle failed: {}", .{err});
}

pub fn queueSubmit(self: *VkBackend, handles: []const CommandBufferHandle) void {
    for (handles) |h| self.device.endCommandBuffer(h) catch |err| log.warn("queueSubmit: endCommandBuffer failed: {}", .{err});
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    const fence = self.device.createFence(&.{}, null) catch |err| {
        log.warn("queueSubmit: createFence failed: {}", .{err});
        return;
    };
    const si = vk.SubmitInfo{
        .command_buffer_count = @intCast(handles.len),
        .p_command_buffers = handles.ptr,
    };
    {
        const zone_qs = tracy.Zone.begin(.{ .name = "queueSubmit", .src = @src(), .color = .tomato });
        defer zone_qs.end();
        self.queue.submit(&.{si}, fence) catch |err| {
            log.warn("queueSubmit: submit failed: {}", .{err});
            self.device.destroyFence(fence, null);
            return;
        };
    }
    const cmds_copy = self.allocator.dupe(vk.CommandBuffer, handles) catch |err| {
        log.warn("queueSubmit: dupe failed: {}", .{err});
        self.device.destroyFence(fence, null);
        return;
    };
    self.submitted_work.append(self.allocator, .{ .cmds = cmds_copy, .fence = fence }) catch |err| {
        log.warn("queueSubmit: append submitted_work failed: {}", .{err});
        self.allocator.free(cmds_copy);
        self.device.destroyFence(fence, null);
        return;
    };
}

pub fn queueSubmitSignal(self: *VkBackend, handles: []const CommandBufferHandle, sem: SemaphoreHandle, value: u64) void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    const ts = vk.TimelineSemaphoreSubmitInfo{
        .signal_semaphore_value_count = 1,
        .p_signal_semaphore_values = @ptrCast(&value),
    };
    const sems = [_]vk.Semaphore{sem};
    const si = vk.SubmitInfo{
        .p_next = @ptrCast(&ts),
        .command_buffer_count = @intCast(handles.len),
        .p_command_buffers = handles.ptr,
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&sems),
    };
    {
        const zone_qss = tracy.Zone.begin(.{ .name = "queueSubmit", .src = @src(), .color = .tomato });
        defer zone_qss.end();
        self.queue.submit(&.{si}, .null_handle) catch |err| log.warn("queueSubmitSignal: submit failed: {}", .{err});
    }
}

pub fn commandsBegin(self: *VkBackend) !CommandBufferHandle {
    // Recycle: free command buffers from completed submissions.
    var i: usize = 0;
    while (i < self.submitted_work.items.len) {
        const work = self.submitted_work.items[i];
        const status = self.device.getFenceStatus(work.fence) catch |err| {
            log.warn("commandsBegin: getFenceStatus failed: {}", .{err});
            i += 1;
            continue;
        };
        if (status == .success) {
            self.device.freeCommandBuffers(self.offscreen_cmd_pool, work.cmds);
            self.device.destroyFence(work.fence, null);
            self.allocator.free(work.cmds);
            _ = self.submitted_work.swapRemove(i);
        } else {
            i += 1;
        }
    }
    var cb: vk.CommandBuffer = undefined;
    try self.device.allocateCommandBuffers(&.{
        .command_pool = self.offscreen_cmd_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cb));
    try self.device.beginCommandBuffer(cb, &.{ .flags = .{ .one_time_submit_bit = true } });
    return cb;
}

pub fn commandsEnd(self: *VkBackend, cmd: CommandBufferHandle) void {
    // queueSubmit handles endCommandBuffer internally.
    // Mark the CB for deferred free after its submission fence completes.
    self.free_cmd_bufs.append(self.allocator, cmd) catch |err| log.warn("commandsEnd: append failed: {}", .{err});
}

pub fn queueWaitIdle(self: *VkBackend) void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    const zone_qw = tracy.Zone.begin(.{ .name = "queueWait", .src = @src(), .color = .tomato });
    defer zone_qw.end();
    self.queue.waitIdle() catch |err| log.warn("queueWaitIdle: waitIdle failed: {}", .{err});
}

pub fn shaderCreate(self: *VkBackend, spv: []const u32, stage: u2, entry: [:0]const u8) !ShaderHandle {
    const vk_stage: vk.ShaderStageFlags = switch (stage) {
        0 => .{ .vertex_bit = true },
        1 => .{ .fragment_bit = true },
        2 => .{ .compute_bit = true },
        else => unreachable,
    };
    const next_stage: vk.ShaderStageFlags = if (vk_stage.vertex_bit) .{ .fragment_bit = true } else .{};
    const pc_range = switch (stage) {
        2 => vk.PushConstantRange{ .stage_flags = .{ .compute_bit = true }, .offset = 0, .size = @sizeOf(ComputePushConstants) },
        else => vk.PushConstantRange{ .stage_flags = .{ .vertex_bit = true, .fragment_bit = true }, .offset = 0, .size = @sizeOf(GraphicsPushConstants) },
    };
    const ci = vk.ShaderCreateInfoEXT{
        .code_type = .spirv_ext,
        .code_size = spv.len * @sizeOf(u32),
        .p_code = @ptrCast(spv.ptr),
        .p_name = entry,
        .stage = vk_stage,
        .next_stage = next_stage,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&pc_range),
        .set_layout_count = 3,
        .p_set_layouts = @ptrCast(&self.desc_layouts),
    };
    var shader_out: [1]vk.ShaderEXT = undefined;
    _ = try self.device.createShadersEXT(
        @ptrCast(&[_]vk.ShaderCreateInfoEXT{ci}),
        null,
        &shader_out,
    );
    return shader_out[0];
}

pub fn shaderDestroy(self: *VkBackend, shader: ShaderHandle) void {
    self.device.destroyShaderEXT(shader, null);
}

// ── Semaphore methods ─────────────────────────────────────────
pub fn semaphoreCreate(self: *VkBackend, initial_value: u64) !SemaphoreHandle {
    return self.device.createSemaphore(
        &.{ .p_next = @constCast(&vk.SemaphoreTypeCreateInfo{
            .semaphore_type = .timeline,
            .initial_value = initial_value,
        }) },
        null,
    );
}
pub fn semaphoreDestroy(self: *VkBackend, sem: SemaphoreHandle) void {
    self.device.destroySemaphore(sem, null);
}

// ── Command buffer methods (VkCmd*) ─────────────────────────

pub fn cmdSetShaders(self: *VkBackend, cmd: CommandBufferHandle, vert: ShaderHandle, frag: ShaderHandle) void {
    const stages: [2]vk.ShaderStageFlags = .{ .{ .vertex_bit = true }, .{ .fragment_bit = true } };
    const shaders: [2]vk.ShaderEXT = .{ vert, frag };
    self.device.cmdBindShadersEXT(cmd, &stages, &shaders);
}

pub fn cmdSetComputeShader(self: *VkBackend, cmd: CommandBufferHandle, shader: ShaderHandle) void {
    const stage = [_]vk.ShaderStageFlags{.{ .compute_bit = true }};
    const shaders = [_]vk.ShaderEXT{shader};
    self.device.cmdBindShadersEXT(cmd, &stage, &shaders);
}

pub fn cmdSetDepthState(self: *VkBackend, cmd: CommandBufferHandle, state: DepthState) void {
    self.device.cmdSetDepthTestEnable(cmd, if (state.mode.read) @as(vk.Bool32, .true) else @as(vk.Bool32, .false));
    self.device.cmdSetDepthWriteEnable(cmd, if (state.mode.write) @as(vk.Bool32, .true) else @as(vk.Bool32, .false));
    self.device.cmdSetDepthCompareOp(cmd, @as(vk.CompareOp, @enumFromInt(@intFromEnum(state.compare))));
    self.device.cmdSetDepthBiasEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetStencilTestEnable(cmd, @as(vk.Bool32, .false));
}

pub fn cmdSetRasterState(self: *VkBackend, cmd: CommandBufferHandle, state: RasterState) void {
    self.device.cmdSetPrimitiveTopology(cmd, @enumFromInt(@intFromEnum(state.topology)));
    self.device.cmdSetCullMode(cmd, @as(vk.CullModeFlags, @bitCast(@as(u32, @intFromEnum(state.cull_mode)))));
    self.device.cmdSetFrontFace(cmd, @as(vk.FrontFace, @enumFromInt(@intFromEnum(state.front_face))));
}

pub fn cmdSetBlendState(self: *VkBackend, cmd: CommandBufferHandle, state: BlendState) void {
    const enable = if (state.enable) @as(vk.Bool32, .true) else @as(vk.Bool32, .false);
    self.device.cmdSetColorBlendEnableEXT(cmd, 0, @as([]const vk.Bool32, &.{enable}));
    const eq = vk.ColorBlendEquationEXT{
        .src_color_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.src_color_factor))),
        .dst_color_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.dst_color_factor))),
        .color_blend_op = @as(vk.BlendOp, @enumFromInt(@intFromEnum(state.color_op))),
        .src_alpha_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.src_alpha_factor))),
        .dst_alpha_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.dst_alpha_factor))),
        .alpha_blend_op = @as(vk.BlendOp, @enumFromInt(@intFromEnum(state.alpha_op))),
    };
    self.device.cmdSetColorBlendEquationEXT(cmd, 0, @as([]const vk.ColorBlendEquationEXT, &.{eq}));
    const write_mask: vk.ColorComponentFlags = @bitCast(@as(u32, @as(u4, @bitCast(state.color_write_mask))));
    self.device.cmdSetColorWriteMaskEXT(cmd, 0, @as([]const vk.ColorComponentFlags, &.{write_mask}));
}

pub fn cmdSetBlendEnable(self: *VkBackend, cmd: CommandBufferHandle, enable: bool) void {
    const vk_enable: vk.Bool32 = if (enable) .true else .false;
    self.device.cmdSetColorBlendEnableEXT(cmd, 0, &.{vk_enable});
}

pub fn cmdSetViewport(self: *VkBackend, cmd: CommandBufferHandle, vp: Viewport) void {
    const vk_vp = vk.Viewport{
        .x = vp.x,
        .y = vp.y,
        .width = vp.width,
        .height = vp.height,
        .min_depth = vp.depth_min,
        .max_depth = vp.depth_max,
    };
    self.device.cmdSetViewportWithCount(cmd, &.{vk_vp});
}

pub fn cmdSetScissor(self: *VkBackend, cmd: CommandBufferHandle, sc: Scissor) void {
    const vk_sc = vk.Rect2D{ .offset = .{ .x = sc.x, .y = sc.y }, .extent = .{ .width = sc.width, .height = sc.height } };
    self.device.cmdSetScissorWithCount(cmd, &.{vk_sc});
}

pub fn cmdPushConstantsGraphics(self: *VkBackend, cmd: CommandBufferHandle, data: PushData) void {
    self.device.cmdPushConstants(cmd, self.pipeline_layout_graphics, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushData), @ptrCast(&data));
}

pub fn cmdPushConstantsCompute(self: *VkBackend, cmd: CommandBufferHandle, data: u64) void {
    self.device.cmdPushConstants(cmd, self.pipeline_layout_compute, .{ .compute_bit = true }, 0, @sizeOf(u64), @ptrCast(&data));
}

pub fn cmdBindIndexBuffer(self: *VkBackend, cmd: CommandBufferHandle, buf: BufferHandle, offset: u64, fmt: IndexFormat) void {
    self.device.cmdBindIndexBuffer(cmd, buf, offset, @as(vk.IndexType, @enumFromInt(@intFromEnum(fmt))));
}

pub fn cmdDraw(self: *VkBackend, cmd: CommandBufferHandle, vertex_count: u32, instance_count: u32) void {
    self.device.cmdDraw(cmd, vertex_count, instance_count, 0, 0);
}

pub fn cmdDrawIndexed(self: *VkBackend, cmd: CommandBufferHandle, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32) void {
    self.device.cmdDrawIndexed(cmd, index_count, instance_count, first_index, vertex_offset, 0);
}

pub fn cmdDrawIndexedIndirect(self: *VkBackend, cmd: CommandBufferHandle, buffer: BufferHandle, offset: u64, draw_count: u32, stride: u32) void {
    self.device.cmdDrawIndexedIndirect(cmd, buffer, offset, draw_count, stride);
}

pub fn cmdDrawIndexedIndirectMulti(self: *VkBackend, cmd: CommandBufferHandle, buffer: BufferHandle, offset: u64, stride: u32, count_buffer: BufferHandle, count_offset: u64, max_draws: u32) void {
    self.device.cmdDrawIndexedIndirectCount(cmd, buffer, offset, count_buffer, count_offset, max_draws, stride);
}

pub fn cmdDispatch(self: *VkBackend, cmd: CommandBufferHandle, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
    self.device.cmdDispatch(cmd, group_count_x, group_count_y, group_count_z);
}

pub fn cmdDispatchIndirect(self: *VkBackend, cmd: CommandBufferHandle, buffer: BufferHandle, offset: u64) void {
    self.device.cmdDispatchIndirect(cmd, buffer, offset);
}

/// Convert Stage packed struct to Vulkan pipeline stage flags explicitly.
/// Avoids fragile @bitCast dependency on matching bit layouts.
fn toVkStageFlags(stage: Stage) vk.PipelineStageFlags2 {
    var flags: vk.PipelineStageFlags2 = .{};
    if (stage.vertex) flags.vertex_shader_bit = true;
    if (stage.fragment) flags.fragment_shader_bit = true;
    if (stage.color_output) flags.color_attachment_output_bit = true;
    if (stage.compute) flags.compute_shader_bit = true;
    if (stage.transfer) flags.all_transfer_bit = true;
    return flags;
}

pub fn cmdBarrier(self: *VkBackend, cmd: CommandBufferHandle, before: Stage, after: Stage, hazards: Hazard) void {
    const src_stage = toVkStageFlags(before);
    const dst_stage = toVkStageFlags(after);
    var src_access: vk.AccessFlags2 = .{};
    var dst_access: vk.AccessFlags2 = .{};
    if (!hazards.descriptors and !hazards.draw_arguments and !hazards.depth_stencil) {
        src_access = .{ .memory_write_bit = true };
        dst_access = .{ .memory_read_bit = true, .memory_write_bit = true };
    } else {
        if (hazards.descriptors) {
            if (before.compute or before.vertex or before.fragment) {
                src_access.shader_write_bit = true;
                dst_access.shader_read_bit = true;
            }
            if (before.transfer) {
                src_access.transfer_write_bit = true;
                dst_access.transfer_read_bit = true;
            }
        }
        if (hazards.draw_arguments) {
            if (before.compute or before.vertex or before.fragment) {
                src_access.shader_write_bit = true;
            }
            dst_access.indirect_command_read_bit = true;
        }
        if (hazards.depth_stencil) {
            src_access.depth_stencil_attachment_write_bit = true;
            dst_access.depth_stencil_attachment_read_bit = true;
            dst_access.depth_stencil_attachment_write_bit = true;
        }
    }
    const barrier = vk.MemoryBarrier2{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
    };
    self.device.cmdPipelineBarrier2(cmd, @ptrCast(&vk.DependencyInfo{
        .memory_barrier_count = 1,
        .p_memory_barriers = @ptrCast(&barrier),
    }));
}

fn resolveTextureDimensions(self: *VkBackend, tex: TextureHandle) ?struct { width: u32, height: u32 } {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return null;
        const win = &self.windows.items[s.window_index];
        return .{ .width = win.extent.width, .height = win.extent.height };
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return null;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return null;
    return .{ .width = info.width, .height = info.height };
}

pub fn cmdBeginRendering(self: *VkBackend, cmd: CommandBufferHandle, desc: Rendering) void {
    const width = if (desc.render_area_size[0] != 0)
        desc.render_area_size[0]
    else if (desc.color_attachments.len > 0)
        (self.resolveTextureDimensions(desc.color_attachments[0].texture) orelse return).width
    else
        0;

    const height = if (desc.render_area_size[1] != 0)
        desc.render_area_size[1]
    else if (desc.color_attachments.len > 0)
        (self.resolveTextureDimensions(desc.color_attachments[0].texture) orelse return).height
    else
        0;

    var color_attach: [8]vk.RenderingAttachmentInfo = undefined;
    const color_count: u32 = @intCast(desc.color_attachments.len);
    if (color_count > 8) {
        log.warn("cmdBeginRendering: color_attachment count {} exceeds max 8, clamping", .{color_count});
    }
    const color_attach_count = @min(color_count, 8);
    for (desc.color_attachments[0..color_attach_count], 0..) |ca, i| {
        const vk_iv = self.resolveTextureView(ca.texture) orelse return;
        color_attach[i] = .{
            .image_view = vk_iv,
            .image_layout = .general,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = @as(vk.AttachmentLoadOp, @enumFromInt(@intFromEnum(ca.load_op))),
            .store_op = @as(vk.AttachmentStoreOp, @enumFromInt(@intFromEnum(ca.store_op))),
            .clear_value = .{ .color = .{ .float_32 = ca.clear_color } },
        };
    }

    var depth_ci: vk.RenderingAttachmentInfo = undefined;
    if (desc.depth_attachment) |da| {
        const vk_iv = self.resolveTextureView(da.texture) orelse return;
        depth_ci = .{
            .image_view = vk_iv,
            .image_layout = .depth_stencil_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = @as(vk.AttachmentLoadOp, @enumFromInt(@intFromEnum(da.load_op))),
            .store_op = @as(vk.AttachmentStoreOp, @enumFromInt(@intFromEnum(da.store_op))),
            .clear_value = .{ .depth_stencil = .{ .depth = da.clear_depth, .stencil = da.clear_stencil } },
        };
    }

    // Transition depth from GENERAL to DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    if (desc.depth_attachment) |depth| {
        const depth_image = self.resolveTextureImage(depth.texture) orelse return;
        const depth_format = self.textures.items[depth.texture.texture.id - 1].format;
        self.last_depth_image = depth_image;
        self.last_depth_format = depth_format;
        const depth_barrier = vk.ImageMemoryBarrier2{
            .image = depth_image,
            .subresource_range = .{
                .aspect_mask = imageAspect(depth_format),
                .base_mip_level = 0,
                .level_count = vk.REMAINING_MIP_LEVELS,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
            .old_layout = .general,
            .new_layout = .depth_stencil_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .early_fragment_tests_bit = true },
            .dst_access_mask = .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true },
        };
        self.device.cmdPipelineBarrier2(cmd, &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = @ptrCast(&depth_barrier) });
    }

    var stencil_ci: vk.RenderingAttachmentInfo = undefined;
    if (desc.stencil_attachment) |sa| {
        const vk_iv = self.resolveTextureView(sa.texture) orelse return;
        stencil_ci = .{
            .image_view = vk_iv,
            .image_layout = .depth_stencil_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = @as(vk.AttachmentLoadOp, @enumFromInt(@intFromEnum(sa.load_op))),
            .store_op = @as(vk.AttachmentStoreOp, @enumFromInt(@intFromEnum(sa.store_op))),
            .clear_value = .{ .depth_stencil = .{ .depth = sa.clear_depth, .stencil = sa.clear_stencil } },
        };
    }

    self.device.cmdBeginRendering(cmd, &.{
        .render_area = .{ .offset = .{ .x = desc.render_area_offset[0], .y = desc.render_area_offset[1] }, .extent = .{ .width = width, .height = height } },
        .layer_count = if (desc.layer_count != 0) desc.layer_count else 1,
        .view_mask = desc.view_mask,
        .color_attachment_count = color_attach_count,
        .p_color_attachments = if (color_count > 0) &color_attach else null,
        .p_depth_attachment = if (desc.depth_attachment != null) @ptrCast(&depth_ci) else null,
        .p_stencil_attachment = if (desc.stencil_attachment != null) @ptrCast(&stencil_ci) else null,
    });

    // Set default dynamic state (no_gfx_api pattern)
    self.device.cmdSetStencilTestEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetRasterizerDiscardEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetPolygonModeEXT(cmd, .fill);
    self.device.cmdSetRasterizationSamplesEXT(cmd, .{ .@"1_bit" = true });
    self.device.cmdSetPrimitiveTopology(cmd, .triangle_list);
    self.device.cmdSetCullMode(cmd, .{ .back_bit = true });
    self.device.cmdSetFrontFace(cmd, .counter_clockwise);
    self.device.cmdSetDepthTestEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetDepthWriteEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetDepthCompareOp(cmd, .less);
    self.device.cmdSetDepthBiasEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetDepthBoundsTestEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetVertexInputEXT(cmd, null, null);
    self.device.cmdSetPrimitiveRestartEnable(cmd, @as(vk.Bool32, .false));
    const sample_mask: vk.SampleMask = 0xFF;
    self.device.cmdSetSampleMaskEXT(cmd, .{ .@"1_bit" = true }, @ptrCast(&sample_mask));
    self.device.cmdSetAlphaToCoverageEnableEXT(cmd, @as(vk.Bool32, .false));
    {
        const blend_enables = [_]vk.Bool32{@as(vk.Bool32, .false)};
        self.device.cmdSetColorBlendEnableEXT(cmd, 0, &blend_enables);
    }
    {
        const color_masks = [_]vk.ColorComponentFlags{.{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true }};
        self.device.cmdSetColorWriteMaskEXT(cmd, 0, &color_masks);
    }
    {
        const blend_eq = [_]vk.ColorBlendEquationEXT{.{
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
        }};
        self.device.cmdSetColorBlendEquationEXT(cmd, 0, &blend_eq);
    }
    const viewport = vk.Viewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 };
    self.device.cmdSetViewportWithCount(cmd, &.{viewport});
    const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
    self.device.cmdSetScissorWithCount(cmd, &.{scissor});
}

pub fn cmdEndRendering(self: *VkBackend, cmd: CommandBufferHandle) void {
    self.device.cmdEndRendering(cmd);
    // Reverse depth barrier: DEPTH_STENCIL_ATTACHMENT_OPTIMAL → GENERAL
    if (self.last_depth_image != .null_handle) {
        const depth_barrier = vk.ImageMemoryBarrier2{
            .image = self.last_depth_image,
            .subresource_range = .{
                .aspect_mask = imageAspect(self.last_depth_format),
                .base_mip_level = 0,
                .level_count = vk.REMAINING_MIP_LEVELS,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
            .old_layout = .depth_stencil_attachment_optimal,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .late_fragment_tests_bit = true },
            .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{},
        };
        self.device.cmdPipelineBarrier2(cmd, &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = @ptrCast(&depth_barrier) });
        self.last_depth_image = .null_handle;
    }
}

pub fn cmdBeginDebugLabel(self: *VkBackend, cmd: CommandBufferHandle, name: [:0]const u8, color: [4]f32) void {
    self.device.cmdBeginDebugUtilsLabelEXT(cmd, @ptrCast(&vk.DebugUtilsLabelEXT{
        .p_label_name = name,
        .color = color,
    }));
}

pub fn cmdEndDebugLabel(self: *VkBackend, cmd: CommandBufferHandle) void {
    self.device.cmdEndDebugUtilsLabelEXT(cmd);
}

pub fn cmdAddWaitSemaphore(self: *VkBackend, window_index: u32, sem: SemaphoreHandle, value: u64) void {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    win.wait_sems[frame].append(self.allocator, sem) catch |e| log.warn("cmdAddWaitSemaphore: append failed: {}", .{e});
    win.wait_values[frame].append(self.allocator, value) catch |e| log.warn("cmdAddWaitSemaphore: append value failed: {}", .{e});
}
pub fn cmdAddSignalSemaphore(self: *VkBackend, window_index: u32, sem: SemaphoreHandle, value: u64) void {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    win.signal_sems[frame].append(self.allocator, sem) catch |e| log.warn("cmdAddSignalSemaphore: append failed: {}", .{e});
    win.signal_values[frame].append(self.allocator, value) catch |e| log.warn("cmdAddSignalSemaphore: append value failed: {}", .{e});
}
pub fn cmdBindDescriptorSets(self: *VkBackend, cmd: CommandBufferHandle, heap: u32) void {
    if (heap < self.desc_heaps.items.len) {
        const dh = self.desc_heaps.items[heap];
        // Bind to both graphics and compute (no_gfx_api pattern)
        self.device.cmdBindDescriptorSets(cmd, .graphics, self.pipeline_layout_graphics, 0, dh.sets[0..], null);
        self.device.cmdBindDescriptorSets(cmd, .compute, self.pipeline_layout_compute, 0, dh.sets[0..], null);
    }
}

pub fn deviceLimits(self: *const VkBackend) DeviceLimits {
    return self.device_limits;
}
pub fn surfaceSize(self: *const VkBackend, window_index: u32) Extent2D {
    if (window_index < self.windows.items.len) return self.windows.items[window_index].extent;
    return .{ .width = 800, .height = 600 };
}
pub fn notifyResize(self: *VkBackend, window_index: u32, size: Extent2D) void {
    if (window_index < self.windows.items.len) {
        const win = &self.windows.items[window_index];
        if (win.requested_extent.width != size.width or win.requested_extent.height != size.height) {
            win.requested_extent = size;
            if (win.resize_throttle == 0) {
                log.info("notifyResize: setting needs_resize (size={}x{})", .{ size.width, size.height });
                win.needs_resize = true;
            } else {
                log.info("notifyResize: deferring (size={}x{}, throttle={})", .{ size.width, size.height, win.resize_throttle });
            }
        }
    }
}

fn recreateSwapchain(self: *VkBackend, win: *Window) !void {
    if (use_swapchain_maintenance1) {
        // Wait on ALL per-frame present fences before destroying old swapchain.
        // Each frame's present must complete before we can safely recreate.
        for (win.present_done_fences.items) |f| {
            const zone_wf_rs = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
            defer zone_wf_rs.end();
            _ = self.device.waitForFences(&[_]vk.Fence{f}, .true, std.math.maxInt(u64)) catch |err| log.warn("recreateSwapchain: waitForFences failed: {}", .{err});
        }
    } else {
        // deviceWaitIdle: Khronos-recommended workaround for spec bug #1678.
        // No fence/semaphore reliably signals when the present engine is done
        // with old swapchain images. deviceWaitIdle is the only safe fallback.
        const zone_dwi_rs = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi_rs.end();
        self.device.deviceWaitIdle() catch |err| log.warn("recreateSwapchain: deviceWaitIdle failed: {}", .{err});
    }
    // Destroy present semaphores
    for (win.present_sems.items) |s| self.device.destroySemaphore(s, null);
    win.present_sems.deinit(self.allocator);
    win.present_sems = .empty;
    // Recreate swapchain (handles old swapchain + images + views)
    try createSwapchainResources(self, win);
    // Recreate present semaphores for new image count
    try createPresentSemaphores(self, win);
    win.needs_resize = false;
    log.info("Swapchain recreated after resize", .{});
}

fn createSwapchainResources(self: *VkBackend, win: *Window) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();
    const alloc = self.allocator;
    const old_swapchain = win.swapchain;

    // Surface capabilities
    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, win.surface);
    log.info("Surface caps: {}x{} -> {}x{}", .{
        caps.current_extent.width,   caps.current_extent.height,
        caps.min_image_extent.width, caps.max_image_extent.width,
    });

    var extent = caps.current_extent;
    if (extent.width == 0xFFFFFFFF or extent.width == 0) {
        extent.width = @max(caps.min_image_extent.width, @min(win.requested_extent.width, caps.max_image_extent.width));
        extent.height = @max(caps.min_image_extent.height, @min(win.requested_extent.height, caps.max_image_extent.height));
    }
    win.extent = .{ .width = extent.width, .height = extent.height }; // actual extent

    // Surface formats
    const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, win.surface, alloc);
    defer alloc.free(formats);
    var chosen_format: vk.SurfaceFormatKHR = formats[0];
    for (formats) |f| {
        if (f.format == .b8g8r8a8_srgb and f.color_space == .srgb_nonlinear_khr) {
            chosen_format = f;
            break;
        }
    }
    win.swapchain_format = chosen_format.format;

    // Present modes
    const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical_device, win.surface, alloc);
    defer alloc.free(present_modes);
    var chosen_present = vk.PresentModeKHR.fifo_khr;
    for (present_modes) |pm| {
        if (pm == .mailbox_khr) {
            chosen_present = pm;
            break;
        }
    }

    // Hand the surface to the device for swapchain maintenance
    const swapchain_ci = vk.SwapchainCreateInfoKHR{
        .surface = win.surface,
        .min_image_count = caps.min_image_count + 1,
        .image_format = chosen_format.format,
        .image_color_space = chosen_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = chosen_present,
        .clipped = .true,
        .old_swapchain = old_swapchain,
    };
    win.swapchain = try self.device.createSwapchainKHR(&swapchain_ci, null);

    if (old_swapchain != .null_handle) {
        for (win.views.items) |v| self.device.destroyImageView(v, null);
        win.views.clearRetainingCapacity();
        win.images.clearRetainingCapacity();
        // First recreation: the on-screen swapchain is retired (destroyed after present).
        // Subsequent recreations (retry loop): the intermediate swapchain was never
        // presented — destroy it immediately.
        if (win.retired_swapchain == .null_handle) {
            win.retired_swapchain = old_swapchain;
        } else {
            self.device.destroySwapchainKHR(old_swapchain, null);
        }
    }

    // Get swapchain images
    const swap_images = try self.device.getSwapchainImagesAllocKHR(win.swapchain, alloc);
    defer alloc.free(swap_images);
    try win.images.appendSlice(alloc, swap_images);

    // Build views atomically: create all into temp list, then swap
    var new_views = std.ArrayList(vk.ImageView).empty;
    errdefer for (new_views.items) |v| self.device.destroyImageView(v, null);
    errdefer new_views.deinit(alloc);
    try new_views.ensureTotalCapacity(alloc, swap_images.len);
    for (swap_images) |img| {
        const view = try self.device.createImageView(&.{
            .image = img,
            .view_type = .@"2d",
            .format = win.swapchain_format,
            .components = .{ .r = .r, .g = .g, .b = .b, .a = .a },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        new_views.appendAssumeCapacity(view);
    }
    // Swap atomically: deinit old, take new
    win.views.deinit(alloc);
    win.views = new_views;
    log.info("Swapchain created: {} images, format {}, extent {}x{}", .{
        swap_images.len, win.swapchain_format, extent.width, extent.height,
    });
}
fn createPerFrameResources(self: *VkBackend, win: *Window) !void {
    const alloc = self.allocator;
    const frames = win.frames_in_flight;

    try win.cmd_pools.ensureTotalCapacity(alloc, frames);
    try win.cmd_buffers.ensureTotalCapacity(alloc, frames);
    try win.cmd_pool_ready.ensureTotalCapacity(alloc, frames);

    for (0..frames) |_| {
        const pool = try self.device.createCommandPool(&.{
            .queue_family_index = self.queue_family_index,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);
        win.cmd_pools.appendAssumeCapacity(pool);

        var cb_handle: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cb_handle));
        win.cmd_buffers.appendAssumeCapacity(.{ .handle = cb_handle, .wrapper = &self.vkd });

        const fence = try self.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        win.cmd_pool_ready.appendAssumeCapacity(fence);
    }
    log.info("Per-frame resources created: {} frames", .{frames});
}

fn createPresentSemaphores(self: *VkBackend, win: *Window) !void {
    const alloc = self.allocator;
    try win.present_sems.ensureTotalCapacity(alloc, win.images.items.len);
    for (win.images.items) |_| {
        const sem = try self.device.createSemaphore(&.{}, null);
        win.present_sems.appendAssumeCapacity(sem);
    }
}
fn destroyWindow(self: *VkBackend, win: *Window) void {
    const alloc = self.allocator;
    for (win.views.items) |v| self.device.destroyImageView(v, null);
    win.views.deinit(alloc);
    for (win.present_sems.items) |s| self.device.destroySemaphore(s, null);
    win.present_sems.deinit(alloc);
    win.images.deinit(alloc);
    for (&win.wait_sems) |*l| l.deinit(alloc);
    for (&win.wait_values) |*l| l.deinit(alloc);
    for (&win.signal_sems) |*l| l.deinit(alloc);
    for (&win.signal_values) |*l| l.deinit(alloc);
    if (win.swapchain != .null_handle) {
        self.device.destroySwapchainKHR(win.swapchain, null);
        win.swapchain = .null_handle;
    }
    if (win.retired_swapchain != .null_handle) {
        self.device.destroySwapchainKHR(win.retired_swapchain, null);
        win.retired_swapchain = .null_handle;
    }
    for (win.cmd_pools.items) |p| self.device.destroyCommandPool(p, null);
    win.cmd_pools.deinit(alloc);
    win.cmd_buffers.deinit(alloc);
    for (win.cmd_pool_ready.items) |f| self.device.destroyFence(f, null);
    win.cmd_pool_ready.deinit(alloc);
    if (use_swapchain_maintenance1) {
        for (win.present_done_fences.items) |f| self.device.destroyFence(f, null);
        win.present_done_fences.deinit(alloc);
    }
    if (win.surface != .null_handle) {
        self.instance.destroySurfaceKHR(win.surface, null);
        win.surface = .null_handle;
    }
}

fn debugCallback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, msg_type: vk.DebugUtilsMessageTypeFlagsEXT, data: [*c]const vk.DebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = user_data;
    const prefix = if (severity.error_bit_ext) "ERROR" else if (severity.warning_bit_ext) "WARN" else "INFO";
    const tag = if (msg_type.validation_bit_ext) "VAL" else if (msg_type.performance_bit_ext) "PERF" else "GEN";
    if (data.*.p_message) |msg| log.info("[{s}:{s}] {s}", .{ tag, prefix, msg });
    return @as(vk.Bool32, .false);
}

// ── GPU memory allocation (no_gfx_api pattern: VkBuffer + VkDeviceMemory) ─

fn toVkFormat(fmt: TextureFormat) vk.Format {
    return switch (fmt) {
        .default => .undefined,
        .r8_unorm => .r8_unorm,
        .rg8_unorm => .r8g8_unorm,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .abgr8_unorm => .a8b8g8r8_unorm_pack32,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .r8_srgb => .r8_srgb,
        .rg8_srgb => .r8g8_srgb,
        .rgba8_srgb => .r8g8b8a8_srgb,
        .abgr8_srgb => .a8b8g8r8_srgb_pack32,
        .bgra8_srgb => .b8g8r8a8_srgb,
        .r16_unorm => .r16_unorm,
        .rg16_unorm => .r16g16_unorm,
        .rgba16_unorm => .r16g16b16a16_unorm,
        .d16_unorm => .d16_unorm,
        .d16_unorm_s8_uint => .d16_unorm_s8_uint,
        .d24_unorm_pack32 => .x8_d24_unorm_pack32,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        .d32_float => .d32_sfloat,
        .r16_float => .r16_sfloat,
        .rg16_float => .r16g16_sfloat,
        .rgba16_float => .r16g16b16a16_sfloat,
        .r32_float => .r32_sfloat,
        .rg32_float => .r32g32_sfloat,
        .rgba32_float => .r32g32b32a32_sfloat,
        .bc1_rgba_unorm => .bc1_rgba_unorm_block,
        .bc3_rgba_unorm => .bc3_unorm_block,
        .bc4_r_unorm => .bc4_unorm_block,
        .bc5_rg_unorm => .bc5_unorm_block,
        .bc6h_rgb_float => .bc6h_ufloat_block,
        .bc7_rgba_unorm => .bc7_unorm_block,
        .bc7_rgba_srgb => .bc7_srgb_block,
        .astc_4x4_rgba_unorm => .astc_4x_4_unorm_block,
        .etc2_rgb8_unorm => .etc2_r8g8b8_unorm_block,
        .etc2_rgba8_unorm => .etc2_r8g8b8a8_unorm_block,
        .eac_r11_unorm => .eac_r11_unorm_block,
        .eac_rg11_unorm => .eac_r11g11_unorm_block,
    };
}
fn toVkImageType(t: TextureType) vk.ImageType {
    return switch (t) {
        .@"1d", .@"1d_array" => .@"1d",
        .@"2d", .@"2d_array", .cube, .cube_array => .@"2d",
        .@"3d" => .@"3d",
    };
}
fn toVkImageViewType(t: TextureType) vk.ImageViewType {
    return switch (t) {
        .@"1d" => .@"1d",
        .@"1d_array" => .@"1d_array",
        .@"2d" => .@"2d",
        .@"2d_array" => .@"2d_array",
        .cube => .cube,
        .cube_array => .cube_array,
        .@"3d" => .@"3d",
    };
}
fn toVkImageUsageFlags(u: TextureUsage) vk.ImageUsageFlags {
    var flags: vk.ImageUsageFlags = .{};
    if (u.sampled) flags.sampled_bit = true;
    if (u.storage) flags.storage_bit = true;
    if (u.transfer_src) flags.transfer_src_bit = true;
    if (u.color_attachment) flags.color_attachment_bit = true;
    if (u.depth_stencil_attachment) flags.depth_stencil_attachment_bit = true;
    return flags;
}
fn toVkFilter(f: Filter) vk.Filter {
    return switch (f) {
        .linear => .linear,
        .nearest => .nearest,
    };
}
fn toVkAddressMode(m: Texture.AddressMode) vk.SamplerAddressMode {
    return switch (m) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
    };
}
fn imageAspect(vk_format: vk.Format) vk.ImageAspectFlags {
    return switch (vk_format) {
        .d16_unorm, .d32_sfloat, .x8_d24_unorm_pack32 => .{ .depth_bit = true },
        .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint => .{ .depth_bit = true, .stencil_bit = true },
        else => .{ .color_bit = true },
    };
}

// ── Texture methods ────────────────────────────────────────────
pub fn textureSizeAndAlign(self: *VkBackend, desc: TextureDesc) struct { size: u64, alignment: u64 } {
    const img_info = vk.ImageCreateInfo{
        .image_type = toVkImageType(desc.type),
        .format = toVkFormat(desc.format),
        .extent = .{ .width = desc.dimensions[0], .height = desc.dimensions[1], .depth = desc.dimensions[2] },
        .mip_levels = desc.mip_count,
        .array_layers = desc.layer_count,
        .samples = @as(vk.SampleCountFlags, @bitCast(desc.sample_count)),
        .tiling = .optimal,
        .usage = toVkImageUsageFlags(desc.usage),
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    var mem_reqs: vk.MemoryRequirements2 = .{
        .memory_requirements = .{
            .size = 0,
            .alignment = 0,
            .memory_type_bits = 0,
        },
    };
    self.device.getDeviceImageMemoryRequirements(&.{
        .p_create_info = &img_info,
        .plane_aspect = .{},
    }, &mem_reqs);
    return .{ .size = mem_reqs.memory_requirements.size, .alignment = mem_reqs.memory_requirements.alignment };
}
pub fn textureCreate(self: *VkBackend, desc: TextureDesc, storage: GpuPtr, queue_index: u32) !TextureHandle {
    _ = queue_index;
    const img_info = vk.ImageCreateInfo{
        .image_type = toVkImageType(desc.type),
        .format = toVkFormat(desc.format),
        .extent = .{ .width = desc.dimensions[0], .height = desc.dimensions[1], .depth = desc.dimensions[2] },
        .mip_levels = desc.mip_count,
        .array_layers = desc.layer_count,
        .samples = switch (desc.sample_count) {
            1 => vk.SampleCountFlags{ .@"1_bit" = true },
            2 => vk.SampleCountFlags{ .@"2_bit" = true },
            4 => vk.SampleCountFlags{ .@"4_bit" = true },
            8 => vk.SampleCountFlags{ .@"8_bit" = true },
            else => vk.SampleCountFlags{ .@"1_bit" = true },
        },
        .tiling = .optimal,
        .usage = blk: {
            var u = toVkImageUsageFlags(desc.usage);
            u.transfer_dst_bit = true;
            break :blk u;
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    const image = try self.device.createImage(&img_info, null);
    errdefer self.device.destroyImage(image, null);

    const owned_memory = storage.vk_buffer == 0;
    const image_memory: vk.DeviceMemory = if (!owned_memory) blk: {
        const target_buf: vk.Buffer = @enumFromInt(storage.vk_buffer);
        break :blk for (self.allocs.items) |a| {
            if (a.buf == target_buf) break a.memory;
        } else return error.OutOfMemory;
    } else blk: {
        const mem_reqs = self.device.getImageMemoryRequirements(image);
        const mem_type_idx = findMemoryType(self, mem_reqs.memory_type_bits, .{ .device_local_bit = true }) orelse return error.OutOfMemory;
        break :blk try self.device.allocateMemory(&.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type_idx,
        }, null);
    };
    errdefer if (owned_memory) self.device.freeMemory(image_memory, null);
    try self.device.bindImageMemory(image, image_memory, 0);

    // Transition UNDEFINED -> GENERAL
    {
        const pool = try self.device.createCommandPool(&.{
            .queue_family_index = self.queue_family_index,
            .flags = .{ .transient_bit = true },
        }, null);
        defer self.device.destroyCommandPool(pool, null);
        var cb: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cb));
        try self.device.beginCommandBuffer(cb, &.{ .flags = .{ .one_time_submit_bit = true } });
        {
            const aspect = imageAspect(toVkFormat(desc.format));
            const barrier = vk.ImageMemoryBarrier2{
                .image = image,
                .subresource_range = .{
                    .aspect_mask = aspect,
                    .base_mip_level = 0,
                    .level_count = desc.mip_count,
                    .base_array_layer = 0,
                    .layer_count = desc.layer_count,
                },
                .old_layout = .undefined,
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
            };
            self.device.cmdPipelineBarrier2(cb, @ptrCast(&vk.DependencyInfo{
                .image_memory_barrier_count = 1,
                .p_image_memory_barriers = @ptrCast(&barrier),
            }));
        }
        try self.device.endCommandBuffer(cb);
        const cb_handle = cb;
        {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            {
                const zone_tc = tracy.Zone.begin(.{ .name = "textureUpload", .src = @src(), .color = .tomato });
                defer zone_tc.end();
                try self.queue.submit(&.{vk.SubmitInfo{
                    .command_buffer_count = 1,
                    .p_command_buffers = @ptrCast(&cb_handle),
                }}, .null_handle);
                try self.queue.waitIdle();
            }
        }
    }

    const view_info = vk.ImageViewCreateInfo{
        .image = image,
        .view_type = toVkImageViewType(desc.type),
        .format = toVkFormat(desc.format),
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = imageAspect(toVkFormat(desc.format)),
            .base_mip_level = 0,
            .level_count = desc.mip_count,
            .base_array_layer = 0,
            .layer_count = desc.layer_count,
        },
    };
    const default_view = try self.device.createImageView(&view_info, null);
    errdefer self.device.destroyImageView(default_view, null);

    try self.textures.append(self.allocator, .{ .image = image, .default_view = default_view, .memory = if (owned_memory) image_memory else .null_handle, .format = toVkFormat(desc.format), .width = desc.dimensions[0], .height = desc.dimensions[1], .depth = desc.dimensions[2], .mip_levels = desc.mip_count });
    return TextureHandle{ .tag = .texture, .texture = .{ .id = @intCast(self.textures.items.len), .birth_frame = 0 } };
}

/// Resolve TextureHandle to vk.Image.
fn resolveTextureImage(self: *VkBackend, tex: TextureHandle) ?vk.Image {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return null;
        const win = &self.windows.items[s.window_index];
        if (s.image_index >= win.images.items.len) return null;
        return win.images.items[s.image_index];
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return null;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return null;
    return info.image;
}
fn resolveTextureFormat(self: *VkBackend, tex: TextureHandle) vk.Format {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return .undefined;
        return self.windows.items[s.window_index].swapchain_format;
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return .undefined;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return .undefined;
    return info.format;
}

/// Resolve TextureHandle to vk.ImageView.
fn resolveTextureView(self: *VkBackend, tex: TextureHandle) ?vk.ImageView {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return null;
        const win = &self.windows.items[s.window_index];
        if (s.image_index >= win.views.items.len) return null;
        return win.views.items[s.image_index];
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return null;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return null;
    return info.default_view;
}

pub fn textureDestroy(self: *VkBackend, tex: TextureHandle) void {
    if (tex.isSwapchain()) return;
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return;
    // Destroy all cached views for this texture
    {
        var keys_to_remove = std.ArrayList(u64).empty;
        defer keys_to_remove.deinit(self.allocator);
        var it = self.texture_view_cache.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* >> 32 == t.id) {
                self.device.destroyImageView(entry.value_ptr.*, null);
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch |err| log.warn("textureCleanup: append failed: {}", .{err});
            }
        }
        for (keys_to_remove.items) |key| {
            _ = self.texture_view_cache.remove(key);
        }
    }
    const info = &self.textures.items[t.id - 1];
    self.pending_free.append(self.allocator, .{ .texture = .{
        .image = info.image,
        .view = info.default_view,
        .memory = info.memory,
    } }) catch |err| log.warn("textureDestroy: append failed: {}", .{err});
    info.* = .{
        .valid = false,
        .image = .null_handle,
        .default_view = .null_handle,
        .memory = .null_handle,
        .format = .undefined,
    };
}

pub fn textureViewDescriptor(self: *VkBackend, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    if (tex.isSwapchain()) return 0;
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return 0;
    const ti = self.textures.items[t.id - 1];

    // Hash the view desc fields (lower 32 bits) + texture id (upper 32 bits)
    var h = std.hash.Wyhash.init(0);
    h.update(&[_]u8{ @intFromEnum(view_desc.type), @intFromEnum(view_desc.format), view_desc.mip_count });
    h.update(std.mem.asBytes(&view_desc.base_mip));
    h.update(std.mem.asBytes(&view_desc.base_layer));
    h.update(std.mem.asBytes(&view_desc.layer_count));
    const view_desc_hash: u32 = @truncate(h.final());
    const cache_key: u64 = (@as(u64, t.id) << 32) | view_desc_hash;

    // Cache hit — return existing view
    if (self.texture_view_cache.get(cache_key)) |cached_view| {
        return @intFromEnum(cached_view);
    }

    // Cache miss — create new view
    const vk_format = if (view_desc.format == .default) ti.format else toVkFormat(view_desc.format);
    const view_info = vk.ImageViewCreateInfo{
        .image = ti.image,
        .view_type = toVkImageViewType(view_desc.type),
        .format = vk_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = imageAspect(vk_format),
            .base_mip_level = view_desc.base_mip,
            .level_count = if (view_desc.mip_count == 0) vk.REMAINING_MIP_LEVELS else view_desc.mip_count,
            .base_array_layer = view_desc.base_layer,
            .layer_count = if (view_desc.layer_count == 0) blk: {
                // 3D images require layerCount=1 (VUID-VkImageViewCreateInfo-image-04971)
                break :blk if (view_desc.type == .@"3d") 1 else vk.REMAINING_ARRAY_LAYERS;
            } else view_desc.layer_count,
        },
    };
    const v = self.device.createImageView(&view_info, null) catch return 0;
    self.texture_view_cache.put(cache_key, v) catch {
        self.device.destroyImageView(v, null);
        return 0;
    };
    return @intFromEnum(v);
}
pub fn textureRwViewDescriptor(self: *VkBackend, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.textureViewDescriptor(tex, view_desc);
}
pub fn samplerDescriptor(self: *VkBackend, desc: SamplerDesc) u64 {
    // Hash the sampler desc fields for cache lookup
    var h = std.hash.Wyhash.init(0);
    h.update(&[_]u8{
        @intFromEnum(desc.min_filter), @intFromEnum(desc.mag_filter), @intFromEnum(desc.mip_filter),
        @intFromEnum(desc.address_mode_u), @intFromEnum(desc.address_mode_v), @intFromEnum(desc.address_mode_w),
    });
    h.update(std.mem.asBytes(&desc.mip_lod_bias));
    h.update(std.mem.asBytes(&desc.min_lod));
    h.update(std.mem.asBytes(&desc.max_lod));
    h.update(std.mem.asBytes(&desc.max_anisotropy));
    const cache_key: u64 = h.final();

    // Cache hit — return existing sampler
    if (self.sampler_cache.get(cache_key)) |cached_sampler| {
        return @intFromEnum(cached_sampler);
    }

    // Cache miss — create new sampler
    const sampler_info = vk.SamplerCreateInfo{
        .mag_filter = toVkFilter(desc.mag_filter),
        .min_filter = toVkFilter(desc.min_filter),
        .mipmap_mode = if (desc.mip_filter == .linear) .linear else .nearest,
        .address_mode_u = toVkAddressMode(desc.address_mode_u),
        .address_mode_v = toVkAddressMode(desc.address_mode_v),
        .address_mode_w = toVkAddressMode(desc.address_mode_w),
        .mip_lod_bias = desc.mip_lod_bias,
        .anisotropy_enable = if (desc.max_anisotropy > 0) @as(vk.Bool32, .true) else .false,
        .max_anisotropy = desc.max_anisotropy,
        .compare_enable = @as(vk.Bool32, @enumFromInt(0)),
        .compare_op = .never,
        .min_lod = desc.min_lod,
        .max_lod = desc.max_lod,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = @as(vk.Bool32, @enumFromInt(0)),
    };
    const s = self.device.createSampler(&sampler_info, null) catch return 0;
    self.sampler_cache.put(cache_key, s) catch {
        self.device.destroySampler(s, null);
        return 0;
    };
    return @intFromEnum(s);
}

// ── Descriptor heap methods ────────────────────────────────────
pub fn descHeapCreate(self: *VkBackend, texture_count: u32, texture_rw_count: u32, sampler_count: u32) !u32 {
    // Pool sizes must be at least as large as the descriptor set layout bindings
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .sampled_image, .descriptor_count = @max(texture_count, max_textures) },
        .{ .type = .storage_image, .descriptor_count = @max(texture_rw_count, max_textures) },
        .{ .type = .sampler, .descriptor_count = @max(sampler_count, max_samplers) },
    };
    const pool = try self.device.createDescriptorPool(&.{
        .flags = .{ .update_after_bind_bit = true, .free_descriptor_set_bit = true },
        .max_sets = 3,
        .pool_size_count = 3,
        .p_pool_sizes = &pool_sizes,
    }, null);
    errdefer self.device.destroyDescriptorPool(pool, null);

    var sets: [3]vk.DescriptorSet = undefined;
    try self.device.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = 3,
        .p_set_layouts = @ptrCast(&self.desc_layouts),
    }, &sets);

    const idx = @as(u32, @intCast(self.desc_heaps.items.len));
    try self.desc_heaps.append(self.allocator, .{ .pool = pool, .sets = sets });
    return idx;
}
pub fn descHeapDestroy(self: *VkBackend, heap_idx: u32) void {
    if (heap_idx < self.desc_heaps.items.len) {
        const dh = &self.desc_heaps.items[heap_idx];
        self.pending_free.append(self.allocator, .{ .desc_heap = .{
            .pool = dh.pool,
            .sets = dh.sets,
        } }) catch |err| log.warn("descHeapDestroy: append failed: {}", .{err});
        // Mark slot invalid instead of swap-removing (keeps indices stable)
        dh.* = .{
            .valid = false,
            .pool = .null_handle,
            .sets = .{ .null_handle, .null_handle, .null_handle },
        };
    }
}
pub fn descHeapSetTextures(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    const buf = self.allocator.alloc(vk.DescriptorImageInfo, descriptors.len) catch return;
    defer self.allocator.free(buf);
    for (descriptors, 0..) |desc, i| {
        buf[i] = .{
            .image_view = @enumFromInt(desc),
            .image_layout = .general,
            .sampler = .null_handle,
        };
    }
    const write = vk.WriteDescriptorSet{
        .dst_set = dh.sets[0],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(descriptors.len),
        .descriptor_type = .sampled_image,
        .p_image_info = buf.ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}
pub fn descHeapSetTexturesRw(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    const buf = self.allocator.alloc(vk.DescriptorImageInfo, descriptors.len) catch return;
    defer self.allocator.free(buf);
    for (descriptors, 0..) |desc, i| {
        buf[i] = .{
            .image_view = @enumFromInt(desc),
            .image_layout = .general,
            .sampler = .null_handle,
        };
    }
    const write = vk.WriteDescriptorSet{
        .dst_set = dh.sets[1],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(descriptors.len),
        .descriptor_type = .storage_image,
        .p_image_info = buf.ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}
pub fn descHeapSetSamplers(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    const buf = self.allocator.alloc(vk.DescriptorImageInfo, descriptors.len) catch return;
    defer self.allocator.free(buf);
    for (descriptors, 0..) |desc, i| {
        buf[i] = .{
            .sampler = @enumFromInt(desc),
            .image_view = .null_handle,
            .image_layout = .undefined,
        };
    }
    const write = vk.WriteDescriptorSet{
        .dst_set = dh.sets[2],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(descriptors.len),
        .descriptor_type = .sampler,
        .p_image_info = buf.ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}

pub fn semaphoreWait(self: *VkBackend, sem: SemaphoreHandle, value: u64) void {
    _ = self.device.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = @ptrCast(&sem),
        .p_values = @ptrCast(&value),
    }, std.math.maxInt(u64)) catch |err| log.warn("waitSemaphore: waitSemaphores failed: {}", .{err});
}

fn isBlockCompressed(fmt: vk.Format) bool {
    return switch (fmt) {
        .bc1_rgb_unorm_block, .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block, .bc1_rgba_srgb_block,
        .bc2_unorm_block, .bc2_srgb_block,
        .bc3_unorm_block, .bc3_srgb_block,
        .bc4_unorm_block, .bc4_snorm_block,
        .bc5_unorm_block, .bc5_snorm_block,
        .bc6h_ufloat_block, .bc6h_sfloat_block,
        .bc7_unorm_block, .bc7_srgb_block,
        => true,
        else => false,
    };
}

pub fn cmdCopyToTexture(self: *VkBackend, cmd: CommandBufferHandle, tex: TextureHandle, src: BufferHandle, region: TextureRegion) void {
    const image = self.resolveTextureImage(tex) orelse return;
    const tex_format = self.resolveTextureFormat(tex);
    const compressed = isBlockCompressed(tex_format);
    const copy = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = if (compressed) 0 else region.size[0],
        .buffer_image_height = if (compressed) 0 else region.size[1],
        .image_subresource = .{
            .aspect_mask = imageAspect(tex_format),
            .mip_level = region.mip_level,
            .base_array_layer = region.base_layer,
            .layer_count = region.layer_count,
        },
        .image_offset = .{ .x = @as(i32, @intCast(region.rect[0])), .y = @as(i32, @intCast(region.rect[1])), .z = @as(i32, @intCast(region.rect[2])) },
        .image_extent = .{ .width = region.size[0], .height = region.size[1], .depth = region.size[2] },
    };
    self.device.cmdCopyBufferToImage(cmd, src, image, .general, &.{copy});
}

pub fn cmdCopyFromTexture(self: *VkBackend, cmd: CommandBufferHandle, src: TextureHandle, dst: BufferHandle, region: TextureRegion) void {
    const image = self.resolveTextureImage(src) orelse return;
    const tex_format = self.resolveTextureFormat(src);
    const compressed = isBlockCompressed(tex_format);
    const copy = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = if (compressed) 0 else region.size[0],
        .buffer_image_height = if (compressed) 0 else region.size[1],
        .image_subresource = .{
            .aspect_mask = imageAspect(tex_format),
            .mip_level = region.mip_level,
            .base_array_layer = region.base_layer,
            .layer_count = region.layer_count,
        },
        .image_offset = .{ .x = @as(i32, @intCast(region.rect[0])), .y = @as(i32, @intCast(region.rect[1])), .z = @as(i32, @intCast(region.rect[2])) },
        .image_extent = .{ .width = region.size[0], .height = region.size[1], .depth = region.size[2] },
    };
    self.device.cmdCopyImageToBuffer(cmd, image, .general, dst, &.{copy});
}

pub fn cmdBlitTexture(self: *VkBackend, cmd: CommandBufferHandle, dst: TextureHandle, dst_rect: BlitRect, src: TextureHandle, src_rect: BlitRect, filter: Filter) void {
    const src_img = self.resolveTextureImage(src) orelse return;
    const dst_img = self.resolveTextureImage(dst) orelse return;
    const src_format = self.resolveTextureFormat(src);
    const dst_format = self.resolveTextureFormat(dst);

    // Resolve zero-rect (both offsets zero) as full-mip blit.
    var src_offsets: [2]vk.Offset3D = .{
        .{ .x = src_rect.offset_a[0], .y = src_rect.offset_a[1], .z = src_rect.offset_a[2] },
        .{ .x = src_rect.offset_b[0], .y = src_rect.offset_b[1], .z = src_rect.offset_b[2] },
    };
    var dst_offsets: [2]vk.Offset3D = .{
        .{ .x = dst_rect.offset_a[0], .y = dst_rect.offset_a[1], .z = dst_rect.offset_a[2] },
        .{ .x = dst_rect.offset_b[0], .y = dst_rect.offset_b[1], .z = dst_rect.offset_b[2] },
    };

    if (src_rect.offset_a[0] == 0 and src_rect.offset_a[1] == 0 and src_rect.offset_a[2] == 0 and
        src_rect.offset_b[0] == 0 and src_rect.offset_b[1] == 0 and src_rect.offset_b[2] == 0)
    {
        if (!src.isSwapchain()) {
            const t = src.texture;
            if (t.id > 0 and t.id <= self.textures.items.len) {
                const info = &self.textures.items[t.id - 1];
                if (info.valid) {
                    const mip_w = @max(1, info.width >> @as(u5, @intCast(src_rect.mip_level)));
                    const mip_h = @max(1, info.height >> @as(u5, @intCast(src_rect.mip_level)));
                    src_offsets[1] = .{ .x = @as(i32, @intCast(mip_w)), .y = @as(i32, @intCast(mip_h)), .z = 1 };
                }
            }
        }
    }
    if (dst_rect.offset_a[0] == 0 and dst_rect.offset_a[1] == 0 and dst_rect.offset_a[2] == 0 and
        dst_rect.offset_b[0] == 0 and dst_rect.offset_b[1] == 0 and dst_rect.offset_b[2] == 0)
    {
        if (!dst.isSwapchain()) {
            const t = dst.texture;
            if (t.id > 0 and t.id <= self.textures.items.len) {
                const info = &self.textures.items[t.id - 1];
                if (info.valid) {
                    const mip_w = @max(1, info.width >> @as(u5, @intCast(dst_rect.mip_level)));
                    const mip_h = @max(1, info.height >> @as(u5, @intCast(dst_rect.mip_level)));
                    dst_offsets[1] = .{ .x = @as(i32, @intCast(mip_w)), .y = @as(i32, @intCast(mip_h)), .z = 1 };
                }
            }
        }
    }

    const blit = vk.ImageBlit{
        .src_subresource = .{
            .aspect_mask = imageAspect(src_format),
            .mip_level = src_rect.mip_level,
            .base_array_layer = src_rect.base_layer,
            .layer_count = src_rect.layer_count,
        },
        .src_offsets = src_offsets,
        .dst_subresource = .{
            .aspect_mask = imageAspect(dst_format),
            .mip_level = dst_rect.mip_level,
            .base_array_layer = dst_rect.base_layer,
            .layer_count = dst_rect.layer_count,
        },
        .dst_offsets = dst_offsets,
    };
    self.device.cmdBlitImage(cmd, src_img, .general, dst_img, .general, &.{blit}, toVkFilter(filter));
}

pub fn gpuMalloc(self: *VkBackend, size: u64, alignment: u29, mem_type: MemoryType) !GpuPtr {
    if (size == 0) return GpuPtr{};

    const usage: vk.BufferUsageFlags = .{
        .shader_device_address_bit = true,
        .storage_buffer_bit = true,
        .vertex_buffer_bit = true,
        .index_buffer_bit = true,
        .transfer_src_bit = true,
        .transfer_dst_bit = true,
        .indirect_buffer_bit = true,
    };
    const buf = try self.device.createBuffer(&vk.BufferCreateInfo{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer self.device.destroyBuffer(buf, null);

    const mem_reqs = self.device.getBufferMemoryRequirements(buf);
    const mem_props: vk.MemoryPropertyFlags = switch (mem_type) {
        .default => .{ .host_visible_bit = true, .host_coherent_bit = true },
        .gpu => .{ .device_local_bit = true },
        .readback => .{ .host_visible_bit = true, .host_cached_bit = true, .host_coherent_bit = true },
    };

    const mem_type_index = findMemoryType(self, mem_reqs.memory_type_bits, mem_props) orelse return error.OutOfMemory;
    const flags_info = vk.MemoryAllocateFlagsInfo{
        .flags = .{ .device_address_bit = true },
        .device_mask = 0,
    };
    const memory = try self.device.allocateMemory(&vk.MemoryAllocateInfo{
        .p_next = @ptrCast(&flags_info),
        .allocation_size = blk: {
            const aligned_size = (mem_reqs.size + alignment - 1) & ~(@as(u64, alignment) - 1);
            break :blk aligned_size;
        },
        .memory_type_index = mem_type_index,
    }, null);
    errdefer self.device.freeMemory(memory, null);

    try self.device.bindBufferMemory(buf, memory, 0);

    var cpu: ?[*]u8 = null;
    if (mem_type != .gpu) {
        cpu = @ptrCast((try self.device.mapMemory(memory, 0, size, .{})).?);
    }

    const addr_info = vk.BufferDeviceAddressInfo{ .buffer = buf };
    const gpu_addr = self.device.getBufferDeviceAddress(&addr_info);

    try self.allocs.append(self.allocator, .{
        .buf = buf,
        .memory = memory,
        .gpu_addr = gpu_addr,
        .cpu = cpu,
        .size = size,
    });
    return .{
        .cpu = if (cpu) |c| c else @ptrCast(@constCast(&[0]u8{})),
        .gpu = gpu_addr,
        .vk_buffer = @intFromEnum(buf),
    };
}

pub fn gpuFree(self: *VkBackend, ptr: GpuPtr) void {
    const target: vk.Buffer = @enumFromInt(ptr.vk_buffer);
    for (self.allocs.items, 0..) |info, i| {
        if (info.buf == target) {
            self.pending_free.append(self.allocator, .{ .buffer = .{
                .buf = info.buf,
                .memory = info.memory,
                .cpu = info.cpu,
            } }) catch |err| log.warn("gpuFree: append failed: {}", .{err});
            _ = self.allocs.swapRemove(i);
            return;
        }
    }
}

pub fn gpuHostToDevicePointer(self: *VkBackend, cpu_ptr: [*]u8) GpuPtr {
    for (self.allocs.items) |alloc| {
        if (alloc.cpu) |base| {
            const start = @intFromPtr(base);
            const end = start + alloc.size;
            const ptr = @intFromPtr(cpu_ptr);
            if (ptr >= start and ptr < end) {
                return .{
                    .cpu = cpu_ptr,
                    .gpu = alloc.gpu_addr + @as(u64, @intCast(ptr - start)),
                };
            }
        }
    }
    return .{ .cpu = cpu_ptr, .gpu = @intFromPtr(cpu_ptr) };
}

pub fn cmdMemCopy(self: *VkBackend, cmd: CommandBufferHandle, src: BufferHandle, dst: BufferHandle, bytes: u64) void {
    self.device.cmdCopyBuffer(cmd, src, dst, &.{vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = bytes,
    }});
}

pub fn cmdSetVertexInput(self: *VkBackend, cmd: CommandBufferHandle, bindings: []const VertexBinding, attributes: []const VertexAttribute) void {
    var vk_bindings: [8]vk.VertexInputBindingDescription2EXT = undefined;
    var vk_attribs: [16]vk.VertexInputAttributeDescription2EXT = undefined;
    const binding_count = @min(bindings.len, 8);
    const attrib_count = @min(attributes.len, 16);
    for (bindings[0..binding_count], 0..) |b, i| {
        vk_bindings[i] = .{ .binding = b.binding, .stride = b.stride, .input_rate = @enumFromInt(b.input_rate), .divisor = 1 };
    }
    for (attributes[0..attrib_count], 0..) |a, i| {
        vk_attribs[i] = .{ .location = a.location, .binding = a.binding, .format = @enumFromInt(a.format), .offset = a.offset };
    }
    self.device.cmdSetVertexInputEXT(cmd, vk_bindings[0..binding_count], vk_attribs[0..attrib_count]);
}

pub fn cmdBindVertexBuffer(self: *VkBackend, cmd: CommandBufferHandle, binding: u32, buf: BufferHandle, offset: u64) void {
    self.device.cmdBindVertexBuffers(cmd, binding, &.{buf}, &.{offset});
}

fn findMemoryType(self: *VkBackend, type_bits: u32, properties: vk.MemoryPropertyFlags) ?u32 {
    for (self.mem_props.memory_types, 0..) |mt, i| {
        if ((type_bits & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and
            mt.property_flags.contains(properties)) return @intCast(i);
    }
    return null;
}
