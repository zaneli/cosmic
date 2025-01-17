const std = @import("std");
const vk = @import("vk");

pub fn createShaderModule(device: vk.VkDevice, src: []align(4) const u8) vk.VkShaderModule {
    const info = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = src.len,
        .pCode = std.mem.bytesAsSlice(u32, src).ptr,
        .pNext = null,
        .flags = 0,
    };
    var mod: vk.VkShaderModule = undefined;
    const res = vk.createShaderModule(device, &info, null, &mod);
    vk.assertSuccess(res);
    return mod;
}