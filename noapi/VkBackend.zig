//! VkBackend — Vulkan 1.4 backend for noapi.
//! Multi-window: each window has its own surface + swapchain, device + queue shared.

const std = @import("std");
const builtin = @import("builtin");
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
const RenderingDesc = @import("Rendering.zig");
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

pub const MaxTextures = 65536;
pub const MaxSamplers = 256;

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
queue_counter: u64 = 0,
queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
io: std.Io,

// Shared descriptor set layouts (no_gfx_api pattern: 3 base sets + optional raytracing)
desc_layouts: [3]vk.DescriptorSetLayout = undefined,
pipeline_layout_graphics: vk.PipelineLayout = undefined,
pipeline_layout_compute: vk.PipelineLayout = undefined,

windows: std.ArrayListUnmanaged(Window) = std.ArrayListUnmanaged(Window).empty,

// Buffer resource pool (no_gfx_api pattern: pooled allocs with handles)
allocs: std.ArrayListUnmanaged(AllocInfo) = .empty,
// Texture pool (index = u32 handle, .id field)
textures: std.ArrayListUnmanaged(TextureInfo) = .empty,
// Descriptor heap pool
desc_heaps: std.ArrayListUnmanaged(DescHeapInfo) = .empty,

const TextureInfo = struct {
    image: vk.Image,
    default_view: vk.ImageView,
    memory: vk.DeviceMemory = .null_handle,
    format: vk.Format,
};

pub const DescHeapInfo = struct {
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

pub const Options = struct {
    app_name: [:0]const u8 = "noapi",
    validation: bool = false,
    frames_in_flight: u32 = 2,
    loader: Loader = .{},
    io: std.Io,

    pub const Loader = struct {
        get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null,
        get_instance_extensions: ?*const fn () []const [*:0]const u8 = null,
    };
};

const DeviceFeatures = struct {
    vk10: vk.PhysicalDeviceFeatures2 = .{ .features = .{} },
    vk12: vk.PhysicalDeviceVulkan12Features = .{},
    vk13: vk.PhysicalDeviceVulkan13Features = .{},
    shader_object: vk.PhysicalDeviceShaderObjectFeaturesEXT = .{},
    descriptor_buffer: vk.PhysicalDeviceDescriptorBufferFeaturesEXT = .{},
    swapchain_maint1: vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT = .{},

    fn init(self: *DeviceFeatures) void {
        self.vk12 = .{
            .runtime_descriptor_array = .true,
            .shader_sampled_image_array_non_uniform_indexing = .true,
            .descriptor_binding_sampled_image_update_after_bind = .true,
            .descriptor_binding_storage_image_update_after_bind = .true,
            .descriptor_binding_partially_bound = .true,
            .timeline_semaphore = .true,
            .buffer_device_address = .true,
            .scalar_block_layout = .true,
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
        self.vk10.p_next = @constCast(&self.vk12);
    }
};

const AllocInfo = extern struct {
    buf: vk.Buffer,
    memory: vk.DeviceMemory,
    gpu_addr: u64,
    cpu: ?[*]u8,
    size: u64,
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
    const alloc = std.heap.page_allocator;
    var self = VkBackend{ .allocator = alloc, .io = options.io };

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

    var enabled_extensions = std.ArrayListUnmanaged([*:0]const u8).empty;
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

    const gpu_props = self.instance.getPhysicalDeviceProperties(self.physical_device);
    log.info("GPU: {s}", .{@as([]const u8, &gpu_props.device_name)});

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

    // ── Descriptor set layouts (no_gfx_api pattern) ─────────
    {
        const flags = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .binding_count = 1,
            .p_binding_flags = @ptrCast(&vk.DescriptorBindingFlags{ .update_after_bind_bit = true, .partially_bound_bit = true }),
        };
        const binding_types = [_]vk.DescriptorType{ .sampled_image, .storage_image, .sampler };
        const binding_counts = [_]u32{ MaxTextures, MaxTextures, MaxSamplers };
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

pub fn deinit(self: *VkBackend) void {
    {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        self.device.deviceWaitIdle() catch {};
    }
    // Free all buffer allocations (fixes exit validation errors)
    for (self.allocs.items) |alloc| {
        if (alloc.cpu != null) self.device.unmapMemory(alloc.memory);
        self.device.destroyBuffer(alloc.buf, null);
        self.device.freeMemory(alloc.memory, null);
    }
    self.allocs.deinit(self.allocator);
    // Destroy all texture images + views
    for (self.textures.items) |ti| {
        self.device.destroyImageView(ti.default_view, null);
        self.device.destroyImage(ti.image, null);
        if (ti.memory != .null_handle) self.device.freeMemory(ti.memory, null);
    }
    self.textures.deinit(self.allocator);
    // Destroy all descriptor heaps
    for (self.desc_heaps.items) |dh| {
        self.device.freeDescriptorSets(dh.pool, dh.sets[0..]) catch {};
        self.device.destroyDescriptorPool(dh.pool, null);
    }
    self.desc_heaps.deinit(self.allocator);
    for (self.windows.items) |*win| if (win.valid) destroyWindow(self, win);
    self.windows.deinit(self.allocator);
    self.device.destroyPipelineLayout(self.pipeline_layout_compute, null);
    self.device.destroyPipelineLayout(self.pipeline_layout_graphics, null);
    for (&self.desc_layouts) |*layout| self.device.destroyDescriptorSetLayout(layout.*, null);
    self.device.destroySemaphore(self.queue_sem, null);
    self.device.destroyDevice(null);
    if (self.debug_messenger != .null_handle)
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
}

pub fn numWindows(self: *const VkBackend) u32 {
    return @as(u32, @intCast(self.windows.items.len));
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
            return @as(u32, @intCast(i));
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
    return @as(u32, @intCast(idx));
}

pub fn removeWindow(self: *VkBackend, index: u32) void {
    if (index < self.windows.items.len and self.windows.items[index].valid) {
        // Drain all pending queue operations before destroying this window's resources.
        // The other thread may have submissions referencing our semaphores/fences on the shared queue.
        self.queue_mutex.lockUncancelable(self.io);
        self.device.deviceWaitIdle() catch {};
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
        log.info("beginFrame: recreating swapchain", .{});
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (use_swapchain_maintenance1) {
            for (win.present_done_fences.items) |f| {
                _ = self.device.waitForFences(&[_]vk.Fence{f}, .true, std.math.maxInt(u64)) catch {};
            }
        } else {
            self.device.deviceWaitIdle() catch {};
        }
        try recreateSwapchain(self, win);
        win.needs_resize = false;
        win.resize_throttle = 2;
    }

    const acq_fence = try self.device.createFence(&.{}, null);
    defer self.device.destroyFence(acq_fence, null);

    const acq = self.device.acquireNextImageKHR(win.swapchain, std.math.maxInt(u64), .null_handle, acq_fence) catch |e| {
        if (e == error.OutOfDateKHR) {
            win.needs_resize = true;
            return error.OutOfDateKHR;
        }
        return e;
    };
    win.image_index = acq.image_index;
    const recreated = acq.result == .suboptimal_khr;
    _ = try self.device.waitForFences(([_]vk.Fence{acq_fence})[0..], .true, std.math.maxInt(u64));

    // Wait for previous frame to finish before reusing pool/fence
    _ = try self.device.waitForFences(win.cmd_pool_ready.items[frame..][0..1], .true, std.math.maxInt(u64));
    try self.device.resetFences(win.cmd_pool_ready.items[frame..][0..1]);
    _ = self.device.resetCommandPool(win.cmd_pools.items[frame], .{}) catch {};

    log.info("beginFrame: acquired idx={} (frame {})", .{ win.image_index, frame });

    // Begin command buffer and transition UNDEFINED -> GENERAL
    win.cmd_buffers.items[frame].beginCommandBuffer(&.{ .flags = .{ .one_time_submit_bit = true } }) catch {};
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
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true },
        };
        win.cmd_buffers.items[frame].pipelineBarrier2(&vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    win.cmd_buffers.items[frame].endCommandBuffer() catch {};

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
    for (win.wait_sems[frame].items, win.wait_values[frame].items, wc..) |s, v, i| {
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
    for (win.signal_sems[frame].items, win.signal_values[frame].items, sc..) |s, v, i| {
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
    self.queue.submit(&.{vk.SubmitInfo{
        .p_next = @constCast(&ts_info),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cb_handle),
        .wait_semaphore_count = wc,
        .p_wait_semaphores = &wait_sems_buf,
        .p_wait_dst_stage_mask = &stage_mask_buf,
        .signal_semaphore_count = sc,
        .p_signal_semaphores = &signal_sems_buf,
    }}, win.cmd_pool_ready.items[frame]) catch {
        return .{ .gpu_blocked_ns = 0 };
    };
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
                _ = self.device.waitForFences(&[_]vk.Fence{pfence}, .true, std.math.maxInt(u64)) catch {};
                self.device.resetFences(&[_]vk.Fence{pfence}) catch {};
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
            log.info("endFrame: presenting idx={} (frame {})", .{ img_idx, frame });
            if (self.queue.presentKHR(&af_present)) |_| {
                if (win.retired_swapchain != .null_handle) {
                    log.info("endFrame: destroying retired swapchain", .{});
                    self.device.destroySwapchainKHR(win.retired_swapchain, null);
                    win.retired_swapchain = .null_handle;
                }
            } else |e| {
                if (e == error.OutOfDateKHR) {
                    log.info("endFrame: present OutOfDateKHR → needs_resize", .{});
                    win.needs_resize = true;
                } else {
                    log.warn("endFrame: present failed: {}", .{e});
                }
            }
        }
    }

    if (win.resize_throttle > 0) win.resize_throttle -= 1;
    win.frame_index = (frame + 1) % win.frames_in_flight;
    if (win.resize_throttle > 0) win.resize_throttle -= 1;
    return .{ .gpu_blocked_ns = 0 };
}
pub fn getCurrentCmdBuf(self: *VkBackend, window_index: u32) CommandBufferHandle {
    const win = &self.windows.items[window_index];
    return win.cmd_buffers.items[win.frame_index].handle;
}

pub fn waitIdle(self: *VkBackend) void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    self.device.deviceWaitIdle() catch {};
}

pub fn queueSubmit(self: *VkBackend, handles: []const CommandBufferHandle) void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    const si = vk.SubmitInfo{
        .command_buffer_count = @intCast(handles.len),
        .p_command_buffers = handles.ptr,
    };
    self.queue.submit(&.{si}, .null_handle) catch {};
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
    self.queue.submit(&.{si}, .null_handle) catch {};
}

pub fn queueWaitIdle(self: *VkBackend) void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    self.queue.waitIdle() catch {};
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
    self.device.cmdSetDepthTestEnable(cmd, state.mode.read);
    self.device.cmdSetDepthWriteEnable(cmd, state.mode.write);
    self.device.cmdSetDepthCompareOp(cmd, @as(vk.CompareOp, @enumFromInt(@intFromEnum(state.compare))));
    self.device.cmdSetDepthBiasEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetStencilTestEnable(cmd, @as(vk.Bool32, .false));
}

pub fn cmdSetRasterState(self: *VkBackend, cmd: CommandBufferHandle, state: RasterState) void {
    const vk_topology: vk.PrimitiveTopology = switch (state.topology) {
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
        .triangle_fan => .triangle_fan,
    };
    self.device.cmdSetPrimitiveTopology(cmd, vk_topology);
    self.device.cmdSetCullMode(cmd, @as(vk.CullModeFlags, @bitCast(@as(u32, @intFromEnum(state.cull_mode)))));
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
    const vk_fmt: vk.IndexType = switch (fmt) {
        .u16 => .uint16,
        .u32 => .uint32,
    };
    self.device.cmdBindIndexBuffer(cmd, buf, offset, vk_fmt);
}

pub fn cmdDraw(self: *VkBackend, cmd: CommandBufferHandle, vertex_count: u32, instance_count: u32) void {
    self.device.cmdDraw(cmd, vertex_count, instance_count, 0, 0);
}

pub fn cmdDrawIndexed(self: *VkBackend, cmd: CommandBufferHandle, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32) void {
    self.device.cmdDrawIndexed(cmd, index_count, instance_count, first_index, vertex_offset, 0);
}

pub fn cmdDispatch(self: *VkBackend, cmd: CommandBufferHandle, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
    self.device.cmdDispatch(cmd, group_count_x, group_count_y, group_count_z);
}

pub fn cmdDispatchIndirect(self: *VkBackend, cmd: CommandBufferHandle, buffer: BufferHandle, offset: u64) void {
    self.device.cmdDispatchIndirect(cmd, buffer, offset);
}

pub fn cmdBarrier(self: *VkBackend, cmd: CommandBufferHandle, before: Stage, after: Stage, hazards: Hazard) void {
    const src_stage = @as(vk.PipelineStageFlags2, @bitCast(before));
    const dst_stage = @as(vk.PipelineStageFlags2, @bitCast(after));
    var src_access: vk.AccessFlags2 = .{};
    var dst_access: vk.AccessFlags2 = .{};
    if (@as(u3, @bitCast(hazards)) == @as(u3, 0)) {
        src_access = .{ .memory_write_bit = true };
        dst_access = .{ .memory_read_bit = true, .memory_write_bit = true };
    } else {
        if (hazards.descriptors) {
            src_access.shader_write_bit = true;
            dst_access.shader_read_bit = true;
        }
        if (hazards.draw_arguments) {
            src_access.shader_write_bit = true;
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

pub fn cmdBeginRendering(self: *VkBackend, cmd: CommandBufferHandle, desc: RenderingDesc) void {
    const width = if (desc.render_area_size[0] != 0) desc.render_area_size[0] else 800;
    const height = if (desc.render_area_size[1] != 0) desc.render_area_size[1] else 600;

    var color_attach: [8]vk.RenderingAttachmentInfo = undefined;
    const color_count: u32 = if (desc.color_attachments.len > 0) @intCast(desc.color_attachments.len) else 1;
    std.debug.assert(color_count <= 8);
    for (desc.color_attachments, 0..) |ca, i| {
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

    self.device.cmdBeginRendering(cmd, &.{
        .render_area = .{ .offset = .{ .x = desc.render_area_offset[0], .y = desc.render_area_offset[1] }, .extent = .{ .width = width, .height = height } },
        .layer_count = if (desc.layer_count != 0) desc.layer_count else 1,
        .view_mask = desc.view_mask,
        .color_attachment_count = color_count,
        .p_color_attachments = &color_attach,
        .p_depth_attachment = if (desc.depth_attachment != null) @ptrCast(&depth_ci) else null,
        .p_stencil_attachment = null,
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
    win.wait_sems[frame].append(self.allocator, sem) catch {};
    win.wait_values[frame].append(self.allocator, value) catch {};
}
pub fn cmdAddSignalSemaphore(self: *VkBackend, window_index: u32, sem: SemaphoreHandle, value: u64) void {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    win.signal_sems[frame].append(self.allocator, sem) catch {};
    win.signal_values[frame].append(self.allocator, value) catch {};
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
    _ = self;
    return .{};
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
            _ = self.device.waitForFences(&[_]vk.Fence{f}, .true, std.math.maxInt(u64)) catch {};
        }
    } else {
        // deviceWaitIdle: Khronos-recommended workaround for spec bug #1678.
        // No fence/semaphore reliably signals when the present engine is done
        // with old swapchain images. deviceWaitIdle is the only safe fallback.
        self.device.deviceWaitIdle() catch {};
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

    const image_count = @max(caps.min_image_count, win.frames_in_flight + 1);
    _ = image_count;

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
    var new_views = std.ArrayListUnmanaged(vk.ImageView).empty;
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
        .d32_float => .d32_sfloat,
        .r16_float => .r16_sfloat,
        .rg16_float => .r16g16_sfloat,
        .rgba16_float => .r16g16b16a16_sfloat,
        .r32_float => .r32_sfloat,
        .rg32_float => .r32g32_sfloat,
        .rgba32_float => .r32g32b32a32_sfloat,
        .bc1_rgba_unorm => .bc1_rgba_unorm_block,
        .bc3_rgba_unorm => .bc3_unorm_block,
        .bc7_rgba_unorm => .bc7_unorm_block,
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
    const reqs = self.device.getDeviceImageMemoryRequirements(&.{ .p_create_info = &img_info });
    return .{ .size = reqs.size, .alignment = reqs.alignment };
}
pub fn textureCreate(self: *VkBackend, desc: TextureDesc, storage: GpuPtr, queue_index: u32) !TextureHandle {
    _ = storage;
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

    const mem_reqs = self.device.getImageMemoryRequirements(image);
    const mem_type_idx = findMemoryType(self, mem_reqs.memory_type_bits, .{ .device_local_bit = true }) orelse return error.OutOfMemory;
    const image_memory = try self.device.allocateMemory(&.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = mem_type_idx,
    }, null);
    errdefer self.device.freeMemory(image_memory, null);
    try self.device.bindImageMemory(image, image_memory, 0);

    // Transition UNDEFINED -> GENERAL (no_gfx_api pattern: lines 1382-1410)
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
            const aspect: vk.ImageAspectFlags = if (desc.format == .d16_unorm or desc.format == .d32_float)
                .{ .depth_bit = true }
            else
                .{ .color_bit = true };
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
            try self.queue.submit(&.{vk.SubmitInfo{
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&cb_handle),
            }}, .null_handle);
            try self.queue.waitIdle();
        }
    }

    const view_info = vk.ImageViewCreateInfo{
        .image = image,
        .view_type = toVkImageViewType(desc.type),
        .format = toVkFormat(desc.format),
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = if (desc.format == .d16_unorm or desc.format == .d32_float)
                .{ .depth_bit = true }
            else
                .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = desc.mip_count,
            .base_array_layer = 0,
            .layer_count = desc.layer_count,
        },
    };
    const default_view = try self.device.createImageView(&view_info, null);
    errdefer self.device.destroyImageView(default_view, null);

    try self.textures.append(self.allocator, .{ .image = image, .default_view = default_view, .memory = image_memory, .format = toVkFormat(desc.format) });
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
    return self.textures.items[t.id - 1].image;
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
    return self.textures.items[t.id - 1].default_view;
}

pub fn textureDestroy(self: *VkBackend, tex: TextureHandle) void {
    if (tex.isSwapchain()) return;
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return;
    const info = self.textures.items[t.id - 1];
    self.device.destroyImageView(info.default_view, null);
    self.device.destroyImage(info.image, null);
    if (info.memory != .null_handle) self.device.freeMemory(info.memory, null);
    _ = self.textures.swapRemove(t.id - 1);
}

pub fn textureViewDescriptor(self: *VkBackend, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    if (tex.isSwapchain()) return 0;
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return 0;
    const ti = self.textures.items[t.id - 1];
    const vk_format = if (view_desc.format == .default) ti.format else toVkFormat(view_desc.format);
    const view_info = vk.ImageViewCreateInfo{
        .image = ti.image,
        .view_type = toVkImageViewType(view_desc.type),
        .format = vk_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = view_desc.base_mip,
            .level_count = if (view_desc.mip_count == 0) vk.REMAINING_MIP_LEVELS else view_desc.mip_count,
            .base_array_layer = view_desc.base_layer,
            .layer_count = if (view_desc.layer_count == 0) vk.REMAINING_ARRAY_LAYERS else view_desc.layer_count,
        },
    };
    const v = self.device.createImageView(&view_info, null) catch return 0;
    return @intFromEnum(v);
}
pub fn textureRwViewDescriptor(self: *VkBackend, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.textureViewDescriptor(tex, view_desc);
}
pub fn samplerDescriptor(self: *VkBackend, desc: SamplerDesc) u64 {
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
    return @intFromEnum(s);
}

// ── Descriptor heap methods ────────────────────────────────────
pub fn descHeapCreate(self: *VkBackend, texture_count: u32, texture_rw_count: u32, sampler_count: u32) !u32 {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .sampled_image, .descriptor_count = texture_count },
        .{ .type = .storage_image, .descriptor_count = texture_rw_count },
        .{ .type = .sampler, .descriptor_count = sampler_count },
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
        const dh = self.desc_heaps.items[heap_idx];
        self.device.freeDescriptorSets(dh.pool, dh.sets[0..]) catch {};
        self.device.destroyDescriptorPool(dh.pool, null);
        // Swap-remove from pool
        self.desc_heaps.items[heap_idx] = self.desc_heaps.items[self.desc_heaps.items.len - 1];
        self.desc_heaps.items.len -= 1;
    }
}
pub fn descHeapSetTextures(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    var tmp: [64]vk.DescriptorImageInfo = undefined;
    const count = @min(descriptors.len, tmp.len);
    for (descriptors[0..count], 0..) |desc, i| {
        tmp[i] = .{
            .image_view = @enumFromInt(desc),
            .image_layout = .shader_read_only_optimal,
            .sampler = .null_handle,
        };
    }
    const write = vk.WriteDescriptorSet{
        .dst_set = dh.sets[0],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(count),
        .descriptor_type = .sampled_image,
        .p_image_info = tmp[0..count].ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}
pub fn descHeapSetTexturesRw(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    var tmp: [64]vk.DescriptorImageInfo = undefined;
    const count = @min(descriptors.len, tmp.len);
    for (descriptors[0..count], 0..) |desc, i| {
        tmp[i] = .{
            .image_view = @enumFromInt(desc),
            .image_layout = .general,
            .sampler = .null_handle,
        };
    }
    const write = vk.WriteDescriptorSet{
        .dst_set = dh.sets[1],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(count),
        .descriptor_type = .storage_image,
        .p_image_info = tmp[0..count].ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}
pub fn descHeapSetSamplers(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    var tmp: [64]vk.DescriptorImageInfo = undefined;
    const count = @min(descriptors.len, tmp.len);
    for (descriptors[0..count], 0..) |desc, i| {
        tmp[i] = .{
            .sampler = @enumFromInt(desc),
            .image_view = .null_handle,
            .image_layout = .undefined,
        };
    }
    const write = vk.WriteDescriptorSet{
        .dst_set = dh.sets[2],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(count),
        .descriptor_type = .sampler,
        .p_image_info = tmp[0..count].ptr,
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
    }, std.math.maxInt(u64)) catch {};
}

pub fn cmdCopyToTexture(self: *VkBackend, cmd: CommandBufferHandle, tex: TextureHandle, src: BufferHandle, region: TextureRegion) void {
    const image = self.resolveTextureImage(tex) orelse return;
    const copy = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = region.mip_level,
            .base_array_layer = region.base_layer,
            .layer_count = region.layer_count,
        },
        .image_offset = .{ .x = @as(i32, @intCast(region.rect[0])), .y = @as(i32, @intCast(region.rect[1])), .z = @as(i32, @intCast(region.rect[2])) },
        .image_extent = .{ .width = region.size[0], .height = region.size[1], .depth = region.size[2] },
    };
    self.device.cmdCopyBufferToImage(cmd, src, image, .general, &.{copy});
}

pub fn cmdBlitTexture(self: *VkBackend, cmd: CommandBufferHandle, dst: TextureHandle, dst_rect: BlitRect, src: TextureHandle, src_rect: BlitRect, filter: Filter) void {
    const src_img = self.resolveTextureImage(src) orelse return;
    const dst_img = self.resolveTextureImage(dst) orelse return;
    const blit = vk.ImageBlit{
        .src_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = src_rect.mip_level,
            .base_array_layer = src_rect.base_layer,
            .layer_count = src_rect.layer_count,
        },
        .src_offsets = .{ .{ .x = src_rect.offset_a[0], .y = src_rect.offset_a[1], .z = src_rect.offset_a[2] }, .{ .x = src_rect.offset_b[0], .y = src_rect.offset_b[1], .z = src_rect.offset_b[2] } },
        .dst_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = dst_rect.mip_level,
            .base_array_layer = dst_rect.base_layer,
            .layer_count = dst_rect.layer_count,
        },
        .dst_offsets = .{ .{ .x = dst_rect.offset_a[0], .y = dst_rect.offset_a[1], .z = dst_rect.offset_a[2] }, .{ .x = dst_rect.offset_b[0], .y = dst_rect.offset_b[1], .z = dst_rect.offset_b[2] } },
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
        .allocation_size = @max(mem_reqs.size, alignment),
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

pub fn gpuFree(self: *VkBackend, idx: u32) void {
    if (idx >= self.allocs.items.len) return;
    const info = self.allocs.items[idx];
    if (info.cpu != null) self.device.unmapMemory(info.memory);
    self.device.destroyBuffer(info.buf, null);
    self.device.freeMemory(info.memory, null);
    // Pool removal: swap with last, shrink (loses original index but handle is invalid now)
    self.allocs.items[idx] = self.allocs.items[self.allocs.items.len - 1];
    self.allocs.items.len -= 1;
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
    for (bindings, 0..) |b, i| {
        vk_bindings[i] = .{ .binding = b.binding, .stride = b.stride, .input_rate = @enumFromInt(b.input_rate), .divisor = 1 };
    }
    for (attributes, 0..) |a, i| {
        vk_attribs[i] = .{ .location = a.location, .binding = a.binding, .format = @enumFromInt(a.format), .offset = a.offset };
    }
    self.device.cmdSetVertexInputEXT(cmd, vk_bindings[0..bindings.len], vk_attribs[0..attributes.len]);
}

pub fn cmdBindVertexBuffer(self: *VkBackend, cmd: CommandBufferHandle, binding: u32, buf: BufferHandle, offset: u64) void {
    self.device.cmdBindVertexBuffers(cmd, binding, &.{buf}, &.{offset});
}

fn findMemoryType(self: *VkBackend, type_bits: u32, properties: vk.MemoryPropertyFlags) ?u32 {
    const mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);
    for (mem_props.memory_types, 0..) |mt, i| {
        if ((type_bits & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and
            mt.property_flags.contains(properties)) return @intCast(i);
    }
    return null;
}

const FrameSchedule = @import("Gpu.zig").FrameSchedule;
const FrameResult = @import("Gpu.zig").FrameResult;
const PresentInfo = @import("Gpu.zig").PresentInfo;
