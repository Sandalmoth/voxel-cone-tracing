pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

const std = @import("std");

const log = std.log.scoped(.sdl);

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

pub fn getError() [*c]const u8 {
    return c.SDL_GetError();
}

pub fn acquireGPUCommandBuffer(device: *GPUDevice) !*GPUCommandBuffer {
    return c.SDL_AcquireGPUCommandBuffer(device) orelse {
        log.err("SDL_AcquireGPUCommandBuffer: {s}", .{getError()});
        return error.Sdl;
    };
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

pub fn createGPUBuffer(device: *GPUDevice, createinfo: *const GPUBufferCreateInfo) !*GPUBuffer {
    return c.SDL_CreateGPUBuffer(device, createinfo) orelse {
        log.err("SDL_CreateGPUBuffer: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUBuffer(device: *GPUDevice, buffer: *GPUBuffer) void {
    c.SDL_ReleaseGPUBuffer(device, buffer);
}

pub fn createGPUTransferBuffer(
    device: *GPUDevice,
    createinfo: *const GPUTransferBufferCreateInfo,
) !*GPUTransferBuffer {
    return c.SDL_CreateGPUTransferBuffer(device, createinfo) orelse {
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
    createinfo: *const GPUShaderCreateInfo,
) *c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(device, createinfo) orelse {
        log.err("SDL_CreateGPUShader: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn createGPUComputePipeline(
    device: *GPUDevice,
    createinfo: *const GPUComputePipelineCreateInfo,
) !*GPUComputePipeline {
    return c.SDL_CreateGPUComputePipeline(device, createinfo) orelse {
        log.err("SDL_CreateGPUComputePipeline: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUComputePipeline(device: *GPUDevice, pipeline: *GPUComputePipeline) void {
    c.SDL_ReleaseGPUComputePipeline(device, pipeline);
}

pub fn createGPUTexture(device: *GPUDevice, createinfo: *const GPUTextureCreateInfo) !*GPUTexture {
    return c.SDL_CreateGPUTexture(device, createinfo) orelse {
        log.err("SDL_CreateGPUTexture: {s}", .{getError()});
        return error.Sdl;
    };
}

pub fn releaseGPUTexture(device: *GPUDevice, texture: *GPUTexture) void {
    c.SDL_ReleaseGPUTexture(device, texture);
}
