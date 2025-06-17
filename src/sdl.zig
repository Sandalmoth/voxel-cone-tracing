pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

const std = @import("std");

const log = std.log.scoped(.sdl);

pub const Window = c.SDL_Window;
pub const Event = c.SDL_Event;

pub const GPUDevice = c.SDL_GPUDevice;
pub const GPUCommandBuffer = c.SDL_GPUCommandBuffer;
pub const GPUCopyPass = c.SDL_GPUCopyPass;
pub const GPUBuffer = c.SDL_GPUBuffer;
pub const GPUBufferCreateInfo = c.SDL_GPUBufferCreateInfo;
pub const GPUTransferBuffer = c.SDL_GPUTransferBuffer;
pub const GPUTransferBufferCreateInfo = c.SDL_GPUTransferBufferCreateInfo;
pub const GPUTransferBufferLocation = c.SDL_GPUTransferBufferLocation;
pub const GPUBufferRegion = c.SDL_GPUBufferRegion;
pub const GPUShaderCreateInfo = c.SDL_GPUShaderCreateInfo;
pub const GPUComputePipelineCreateInfo = c.SDL_GPUComputePipelineCreateInfo;
pub const GPUComputePipeline = c.SDL_GPUComputePipeline;
pub const GPUTextureCreateInfo = c.SDL_GPUTextureCreateInfo;
pub const GPUTexture = c.SDL_GPUTexture;
pub const GPUComputePass = c.SDL_GPUComputePass;
pub const GPUStorageTextureReadWriteBinding = c.SDL_GPUStorageTextureReadWriteBinding;
pub const GPUStorageBufferReadWriteBinding = c.SDL_GPUStorageBufferReadWriteBinding;
pub const GPUGraphicsPipeline = c.SDL_GPUGraphicsPipeline;
pub const GPUSampler = c.SDL_GPUSampler;
pub const GPUShader = c.SDL_GPUShader;
pub const GPUVertexBufferDescription = c.SDL_GPUVertexBufferDescription;
pub const GPUVertexAttribute = c.SDL_GPUVertexAttribute;
pub const GPUColorTargetDescription = c.SDL_GPUColorTargetDescription;
pub const GPUGraphicsPipelineCreateInfo = c.SDL_GPUGraphicsPipelineCreateInfo;
pub const GPUSamplerCreateInfo = c.SDL_GPUSamplerCreateInfo;
pub const GPUColorTargetInfo = c.SDL_GPUColorTargetInfo;
pub const GPURenderPass = c.SDL_GPURenderPass;
pub const GPUDepthStencilTargetInfo = c.SDL_GPUDepthStencilTargetInfo;
pub const GPUBufferBinding = c.SDL_GPUBufferBinding;
pub const GPUTextureSamplerBinding = c.SDL_GPUTextureSamplerBinding;
pub const FColor = c.SDL_FColor;
pub const GPUFence = c.SDL_GPUFence;

pub fn getError() [*c]const u8 {
    return c.SDL_GetError();
}

pub fn acquireGPUCommandBuffer(device: *GPUDevice) !*GPUCommandBuffer {
    const command_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        log.err("SDL_AcquireGPUCommandBuffer: {s}", .{getError()});
        return error.Sdl;
    };
    // BUG BUG BUG
    // this is a workaround for an error in SDL where a value is left uninitialized
    // TODO TODO TODO
    // remove when it gets fixed upstream
    const CommandBufferCommonHeader = extern struct {
        device: *anyopaque,
        render_pass: extern struct {
            command_buffer: *anyopaque,
            in_progress: bool,
            color_targets: [4]*anyopaque,
            num_color_targets: u32,
            depth_stencil_target: *anyopaque,
            graphics_pipeline: *anyopaque,
            vertex_sampler_bound: [16]bool,
            vertex_storage_texture_bound: [8]bool,
            vertex_storage_buffer_bound: [8]bool,
            fragment_sampler_bound: [16]bool,
            fragment_storage_texture_bound: [8]bool,
            fragment_storage_buffer_bound: [8]bool,
        },
        computepass: extern struct {
            command_buffer: *anyopaque,
            in_progress: bool,
            compute_pipeline: *anyopaque,
            sampler_bound: [16]bool,
            read_only_storage_texture_bound: [8]bool,
            read_only_storage_buffer_bound: [8]bool,
            read_write_storage_texture_bound: [8]bool,
            read_write_storage_buffer_bound: [8]bool,
        },
        copy_pass: extern struct {
            command_buffer: *anyopaque,
            in_progress: bool,
        },
        swapchain_texture_acquired: bool,
        submitted: bool,
        ignore_render_pass_texture_validation: bool,
    };
    @as(*CommandBufferCommonHeader, @alignCast(@ptrCast(command_buffer)))
        .ignore_render_pass_texture_validation = false;
    return command_buffer;
}

pub fn submitGPUCommandBuffer(command_buffer: *GPUCommandBuffer) !void {
    if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        log.err("SDL_SubmitGPUCommandBuffer: {s}", .{getError()});
        return error.Sdl;
    }
}

pub fn beginGPUCopyPass(command_buffer: *GPUCommandBuffer) !*GPUCopyPass {
    return c.SDL_BeginGPUCopyPass(command_buffer) orelse {
        log.err("SDL_BeginGPUCopyPass: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn endGPUCopyPass(copy_pass: *GPUCopyPass) void {
    c.SDL_EndGPUCopyPass(copy_pass);
}

pub fn createGPUBuffer(device: *GPUDevice, create_info: *const GPUBufferCreateInfo) !*GPUBuffer {
    return c.SDL_CreateGPUBuffer(device, create_info) orelse {
        log.err("SDL_CreateGPUBuffer: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUBuffer(device: *GPUDevice, buffer: *GPUBuffer) void {
    c.SDL_ReleaseGPUBuffer(device, buffer);
}

pub fn createGPUTransferBuffer(
    device: *GPUDevice,
    create_info: *const GPUTransferBufferCreateInfo,
) !*GPUTransferBuffer {
    return c.SDL_CreateGPUTransferBuffer(device, create_info) orelse {
        log.err("SDL_CreateGPUTransferBuffer: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUTransferBuffer(device: *GPUDevice, buffer: *GPUTransferBuffer) void {
    c.SDL_ReleaseGPUTransferBuffer(device, buffer);
}

pub fn mapGPUTransferBuffer(
    device: *GPUDevice,
    buffer: *GPUTransferBuffer,
    cycle: bool,
) !*anyopaque {
    return c.SDL_MapGPUTransferBuffer(device, buffer, cycle) orelse {
        log.err("SDL_MapGPUTransferBuffer: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn unmapGPUTransferBuffer(device: *GPUDevice, buffer: *GPUTransferBuffer) void {
    c.SDL_UnmapGPUTransferBuffer(device, buffer);
}

pub fn uploadToGPUBuffer(
    copy_pass: *GPUCopyPass,
    source: *const GPUTransferBufferLocation,
    destination: *const GPUBufferRegion,
    cycle: bool,
) void {
    c.SDL_UploadToGPUBuffer(copy_pass, source, destination, cycle);
}

pub fn createGPUShader(
    device: *GPUDevice,
    create_info: *const GPUShaderCreateInfo,
) !*GPUShader {
    return c.SDL_CreateGPUShader(device, create_info) orelse {
        log.err("SDL_CreateGPUShader: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUShader(device: *GPUDevice, shader: *GPUShader) void {
    c.SDL_ReleaseGPUShader(device, shader);
}

pub fn createGPUComputePipeline(
    device: *GPUDevice,
    create_info: *const GPUComputePipelineCreateInfo,
) !*GPUComputePipeline {
    return c.SDL_CreateGPUComputePipeline(device, create_info) orelse {
        log.err("SDL_CreateGPUComputePipeline: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUComputePipeline(device: *GPUDevice, pipeline: *GPUComputePipeline) void {
    c.SDL_ReleaseGPUComputePipeline(device, pipeline);
}

pub fn createGPUTexture(
    device: *GPUDevice,
    create_info: *const GPUTextureCreateInfo,
) !*GPUTexture {
    return c.SDL_CreateGPUTexture(device, create_info) orelse {
        log.err("SDL_CreateGPUTexture: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUTexture(device: *GPUDevice, texture: *GPUTexture) void {
    c.SDL_ReleaseGPUTexture(device, texture);
}

pub fn setMainReady() void {
    c.SDL_SetMainReady();
}

pub fn init(flags: u32) !void {
    if (!c.SDL_Init(flags)) {
        log.err("SDL_Init: {s}", .{getError()});
        return error.Sdl;
    }
}

pub fn quit() void {
    c.SDL_Quit();
}

pub fn createWindow(title: []const u8, w: c_int, h: c_int, flags: u64) !*Window {
    return c.SDL_CreateWindow(title.ptr, w, h, flags) orelse {
        log.err("SDL_CreateWindow: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn destroyWindow(window: *Window) void {
    c.SDL_DestroyWindow(window);
}

pub fn setWindowRelativeMouseMode(window: *Window, enabled: bool) !void {
    if (!c.SDL_SetWindowRelativeMouseMode(window, enabled)) {
        log.err("SDL_SetWindowRelativeMouseMode: {s}", .{getError()});
        return error.Sdl;
    }
}

pub fn createGPUDevice(format_flags: u32, debug_mode: bool, name: ?[]const u8) !*GPUDevice {
    return c.SDL_CreateGPUDevice(
        format_flags,
        debug_mode,
        if (name == null) null else name.?.ptr,
    ) orelse {
        log.err("SDL_CreateGPUDevice: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn destroyGPUDevice(device: *GPUDevice) void {
    c.SDL_DestroyGPUDevice(device);
}

pub fn claimWindowForGPUDevice(device: *GPUDevice, window: *Window) !void {
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        log.err("SDL_ClaimWindowForGPUDevice: {s}", .{getError()});
        return error.Sdl;
    }
}

pub fn getGPUSwapchainTextureFormat(device: *GPUDevice, window: *Window) c_uint {
    return c.SDL_GetGPUSwapchainTextureFormat(device, window);
}

pub fn createGPUGraphicsPipeline(
    device: *GPUDevice,
    create_info: *const GPUGraphicsPipelineCreateInfo,
) !*GPUGraphicsPipeline {
    return c.SDL_CreateGPUGraphicsPipeline(device, create_info) orelse {
        log.err("SDL_CreateGPUGraphicsPipeline: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUGraphicsPipeline(device: *GPUDevice, pipeline: *GPUGraphicsPipeline) void {
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
}

pub fn createGPUSampler(
    device: *GPUDevice,
    create_info: *const GPUSamplerCreateInfo,
) !*GPUSampler {
    return c.SDL_CreateGPUSampler(device, create_info) orelse {
        log.err("SDL_CreateGPUSampler: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUSampler(device: *GPUDevice, sampler: *GPUSampler) void {
    c.SDL_ReleaseGPUSampler(device, sampler);
}

pub fn waitAndAcquireGPUSwapchainTexture(
    command_buffer: *GPUCommandBuffer,
    window: *Window,
    swapchain_texture: *?*GPUTexture,
    swapchain_texture_width: ?*u32,
    swapchain_texture_height: ?*u32,
) !void {
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(
        command_buffer,
        window,
        swapchain_texture,
        swapchain_texture_width,
        swapchain_texture_height,
    )) {
        log.err("SDL_WaitAndAcquireGPUSwapchainTexture: {s}", .{getError()});
        return error.Sdl;
    }
}

pub fn beginGPURenderPass(
    command_buffer: *GPUCommandBuffer,
    color_target_infos: []const GPUColorTargetInfo,
    depth_stencil_target_info: ?*const GPUDepthStencilTargetInfo,
) !*GPURenderPass {
    return c.SDL_BeginGPURenderPass(
        command_buffer,
        if (color_target_infos.len == 0) null else &color_target_infos[0],
        @intCast(color_target_infos.len),
        depth_stencil_target_info,
    ) orelse {
        log.err("SDL_BeginGPURenderPass: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn endGPURenderPass(render_pass: *GPURenderPass) void {
    c.SDL_EndGPURenderPass(render_pass);
}

pub fn bindGPUGraphicsPipeline(
    pass: *GPURenderPass,
    pipeline: *GPUGraphicsPipeline,
) void {
    c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
}

pub fn bindGPUVertexBuffers(
    pass: *GPURenderPass,
    first_slot: u32,
    bindings: []const GPUBufferBinding,
) void {
    std.debug.assert(bindings.len > 0);
    c.SDL_BindGPUVertexBuffers(
        pass,
        first_slot,
        &bindings[0],
        @intCast(bindings.len),
    );
}

pub fn bindGPUFragmentSamplers(
    pass: *GPURenderPass,
    first_slot: u32,
    bindings: []const GPUTextureSamplerBinding,
) void {
    std.debug.assert(bindings.len > 0);
    c.SDL_BindGPUFragmentSamplers(
        pass,
        first_slot,
        &bindings[0],
        @intCast(bindings.len),
    );
}

pub fn drawGPUPrimitives(
    pass: *GPURenderPass,
    num_vertices: u32,
    num_instances: u32,
    first_vertex: u32,
    first_instance: u32,
) void {
    c.SDL_DrawGPUPrimitives(pass, num_vertices, num_instances, first_vertex, first_instance);
}

pub fn drawGPUIndexedPrimitives(
    pass: *GPURenderPass,
    num_indices: u32,
    num_instances: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
) void {
    c.SDL_DrawGPUIndexedPrimitives(
        pass,
        num_indices,
        num_instances,
        first_index,
        vertex_offset,
        first_instance,
    );
}

pub fn bindGPUIndexBuffer(
    pass: *GPURenderPass,
    binding: *const GPUBufferBinding,
    index_element_size: c_uint,
) void {
    c.SDL_BindGPUIndexBuffer(pass, binding, index_element_size);
}

pub fn pushGPUVertexUniformData(
    command_buffer: *GPUCommandBuffer,
    slot_index: u32,
    data: *const anyopaque,
    length: u32,
) void {
    c.SDL_PushGPUVertexUniformData(command_buffer, slot_index, data, length);
}

pub fn pushGPUFragmentUniformData(
    command_buffer: *GPUCommandBuffer,
    slot_index: u32,
    data: *const anyopaque,
    length: u32,
) void {
    c.SDL_PushGPUFragmentUniformData(command_buffer, slot_index, data, length);
}

pub fn beginGPUComputePass(
    command_buffer: *GPUCommandBuffer,
    storage_texture_bindings: []const GPUStorageTextureReadWriteBinding,
    storage_buffer_bindings: []const GPUStorageBufferReadWriteBinding,
) !*GPUComputePass {
    return c.SDL_BeginGPUComputePass(
        command_buffer,
        if (storage_texture_bindings.len == 0) null else &storage_texture_bindings[0],
        @intCast(storage_texture_bindings.len),
        if (storage_buffer_bindings.len == 0) null else &storage_buffer_bindings[0],
        @intCast(storage_buffer_bindings.len),
    ) orelse {
        log.err("SDL_BeginGPUComputePass: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn bindGPUComputePipeline(pass: *GPUComputePass, pipeline: *GPUComputePipeline) void {
    c.SDL_BindGPUComputePipeline(pass, pipeline);
}

pub fn dispatchGPUCompute(
    pass: *GPUComputePass,
    groupcount_x: u32,
    groupcount_y: u32,
    groupcount_z: u32,
) void {
    c.SDL_DispatchGPUCompute(pass, groupcount_x, groupcount_y, groupcount_z);
}

pub fn endGPUComputePass(pass: *GPUComputePass) void {
    c.SDL_EndGPUComputePass(pass);
}

pub fn bindGPUComputeStorageBuffers(
    pass: *GPUComputePass,
    first_slot: u32,
    bindings: []const *GPUBuffer,
) void {
    std.debug.assert(bindings.len > 0);
    c.SDL_BindGPUComputeStorageBuffers(
        pass,
        first_slot,
        &bindings[0],
        @intCast(bindings.len),
    );
}

pub fn bindGPUComputeStorageTextures(
    pass: *GPUComputePass,
    first_slot: u32,
    bindings: []const *GPUTexture,
) void {
    std.debug.assert(bindings.len > 0);
    c.SDL_BindGPUComputeStorageTextures(
        pass,
        first_slot,
        &bindings[0],
        @intCast(bindings.len),
    );
}

pub fn pushGPUComputeUniformData(
    command_buffer: *GPUCommandBuffer,
    slot_index: u32,
    data: *const anyopaque,
    length: u32,
) void {
    c.SDL_PushGPUComputeUniformData(command_buffer, slot_index, data, length);
}

pub fn bindGPUComputeSamplers(
    pass: *GPUComputePass,
    first_slot: u32,
    bindings: []const GPUTextureSamplerBinding,
) void {
    std.debug.assert(bindings.len > 0);
    c.SDL_BindGPUComputeSamplers(
        pass,
        first_slot,
        &bindings[0],
        @intCast(bindings.len),
    );
}

pub fn windowSupportsGPUPresentMode(
    device: *GPUDevice,
    window: *Window,
    present_mode: c_uint,
) bool {
    return c.SDL_WindowSupportsGPUPresentMode(device, window, present_mode);
}

pub fn setGPUSwapchainParameters(
    device: *GPUDevice,
    window: *Window,
    swapchain_composition: c_uint,
    present_mode: c_uint,
) !void {
    if (!c.SDL_SetGPUSwapchainParameters(
        device,
        window,
        swapchain_composition,
        present_mode,
    )) {
        log.err("SDL_SetGPUSwapchainParameters: {s}", .{getError()});
        return error.Sdl;
    }
}

pub fn dispatchGPUComputeIndirect(pass: *GPUComputePass, buffer: *GPUBuffer, offset: u32) void {
    c.SDL_DispatchGPUComputeIndirect(pass, buffer, offset);
}

pub fn pushGPUDebugGroup(command_buffer: *GPUCommandBuffer, name: [:0]const u8) void {
    c.SDL_PushGPUDebugGroup(command_buffer, name.ptr);
}

pub fn popGPUDebugGroup(command_buffer: *GPUCommandBuffer) void {
    c.SDL_PopGPUDebugGroup(command_buffer);
}

pub fn getGPUDeviceDriver(device: *GPUDevice) []const u8 {
    const driver = c.SDL_GetGPUDeviceDriver(device);
    if (driver == null) return "UNKNOWN";
    return std.mem.span(driver);
}

pub fn submitGPUCommandBufferAndAcquireFence(command_buffer: *GPUCommandBuffer) !*GPUFence {
    return c.SDL_SubmitGPUCommandBufferAndAcquireFence(command_buffer) orelse {
        log.err("SDL_SubmitGPUCommandBufferAndAcquireFence: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn waitForGPUFences(device: *GPUDevice, wait_all: bool, fences: []const *GPUFence) !void {
    if (!c.SDL_WaitForGPUFences(device, wait_all, &fences[0], @intCast(fences.len))) {
        log.err("SDL_WaitForGPUFences: {s}", .{getError()});
        return error.Sdl;
    }
}

pub fn releaseGPUFence(device: *GPUDevice, fence: *GPUFence) void {
    c.SDL_ReleaseGPUFence(device, fence);
}

pub fn downloadFromGPUBuffer(
    pass: *GPUCopyPass,
    source: *const GPUBufferRegion,
    destination: *const GPUTransferBufferLocation,
) void {
    c.SDL_DownloadFromGPUBuffer(pass, source, destination);
}
