const std = @import("std");
const stdx = @import("stdx");
const fatal = stdx.fatal;
const vk = @import("vk");

pub fn updateDescriptorSet(device: vk.VkDevice, desc_set: vk.VkDescriptorSet, image_infos: []vk.VkDescriptorImageInfo) void {
    const write = vk.VkWriteDescriptorSet{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = desc_set,
        .dstBinding = 0,
        .dstArrayElement = 0,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = @intCast(u32, image_infos.len),
        .pImageInfo = image_infos.ptr,
        .pNext = null,
        .pBufferInfo = null,
        .pTexelBufferView = null,
    };
    vk.updateDescriptorSets(device, 1, &write, 0, null);
}

pub fn createDescriptorSets(alloc: std.mem.Allocator, device: vk.VkDevice, pool: vk.VkDescriptorPool, n: u32, layout: vk.VkDescriptorSetLayout) []vk.VkDescriptorSet {
    const layouts = alloc.alloc(vk.VkDescriptorSetLayout, n) catch fatal();
    defer alloc.free(layouts);
    for (layouts) |_, i| {
        layouts[i] = layout;
    }
    var sets = alloc.alloc(vk.VkDescriptorSet, n) catch fatal();
    const alloc_info = vk.VkDescriptorSetAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = n,
        .pSetLayouts = layouts.ptr,
        .pNext = null,
    };
    const res = vk.allocateDescriptorSets(device, &alloc_info, sets.ptr);
    vk.assertSuccess(res);
    return sets;
}

pub fn createDescriptorSet(device: vk.VkDevice, pool: vk.VkDescriptorPool, layout: vk.VkDescriptorSetLayout) vk.VkDescriptorSet {
    var ret: vk.VkDescriptorSet = undefined;
    const alloc_info = vk.VkDescriptorSetAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layout,
        .pNext = null,
    };
    const res = vk.allocateDescriptorSets(device, &alloc_info, &ret);
    vk.assertSuccess(res);
    return ret;
}