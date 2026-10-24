#include "dc_vk_sprite.h"
#include <vulkan/vulkan.h>
#ifdef __APPLE__
#include <vulkan/vulkan_metal.h>
#include <TargetConditionals.h>
#endif
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <math.h>
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#include <pthread.h>
#endif

typedef struct host_buffer {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *mapped;
    VkDeviceSize bytes;
} host_buffer;

typedef struct texture {
    uintptr_t id;
    uint32_t opaque;
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkDescriptorSet sets[2];
} texture;

typedef struct prepared_draw {
    dc_sprite_vertex vertices[4];
    const dc_sprite_vertex *source;
    size_t count;
    VkDeviceSize offset;
    texture *image;
    uint32_t pipeline, filter, alpha_op;
} prepared_draw;

struct dc_vk_sprite {
    VkInstance instance;
    VkDebugUtilsMessengerEXT debug;
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_debug;
    VkPhysicalDevice physical;
    VkPhysicalDeviceMemoryProperties memory_properties;
    VkDevice device;
    VkQueue queue;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkImage *present_images;
    uint32_t present_count;
    VkExtent2D present_extent;
    VkSemaphore acquired, rendered;
    uint32_t queue_family;
    VkCommandPool command_pool;
    VkCommandBuffer command;
    VkFence fence;
    VkImage target;
    VkDeviceMemory target_memory;
    VkImageView target_view;
    VkImage depth;
    VkDeviceMemory depth_memory;
    VkImageView depth_view;
    VkRenderPass render_pass;
    VkFramebuffer framebuffer;
    VkDescriptorSetLayout descriptor_layout;
    VkDescriptorPool descriptor_pool;
    VkPipelineLayout pipeline_layout;
    VkShaderModule modules[2];
    VkPipeline pipelines[6];
    VkSampler samplers[2];
    host_buffer readback, vertices;
    texture *textures;
    uint32_t width, height, max_textures, initial_filter, broken;
    uintptr_t next_texture;
    dc_vk_sprite_info info;
    char error[512];
};

static dc_status fail(dc_vk_sprite *r, dc_status code, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(r->error, sizeof(r->error), format, args);
    va_end(args);
    return code;
}

static dc_status vk_fail(dc_vk_sprite *r, VkResult result, const char *operation) {
    if (result == VK_ERROR_DEVICE_LOST) r->broken = 1;
    return fail(r, DC_IO, "%s failed (VkResult %d)", operation, (int)result);
}

#define VK_CHECK(expression) do { VkResult result_ = (expression); \
    if (result_ != VK_SUCCESS) return vk_fail(r, result_, #expression); } while (0)

static VKAPI_ATTR VkBool32 VKAPI_CALL debug_message(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
        VkDebugUtilsMessageTypeFlagsEXT types, const VkDebugUtilsMessengerCallbackDataEXT *data, void *user) {
    dc_vk_sprite *r = user;
    (void)types;
    if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        ++r->info.validation_errors;
        fprintf(stderr, "Vulkan validation error: %s\n", data->pMessage);
    }
    return VK_FALSE;
}

static int extension_present(const VkExtensionProperties *items, uint32_t count, const char *name) {
    for (uint32_t i = 0; i < count; ++i)
        if (!strcmp(items[i].extensionName, name)) return 1;
    return 0;
}

static int memory_type(dc_vk_sprite *r, uint32_t bits, VkMemoryPropertyFlags flags, uint32_t *out) {
    for (uint32_t i = 0; i < r->memory_properties.memoryTypeCount; ++i) {
        if ((bits & (1u << i)) && (r->memory_properties.memoryTypes[i].propertyFlags & flags) == flags) {
            *out = i;
            return 1;
        }
    }
    return 0;
}

static void drop_buffer(dc_vk_sprite *r, host_buffer *buffer) {
    if (buffer->mapped) vkUnmapMemory(r->device, buffer->memory);
    if (buffer->buffer) vkDestroyBuffer(r->device, buffer->buffer, NULL);
    if (buffer->memory) vkFreeMemory(r->device, buffer->memory, NULL);
    memset(buffer, 0, sizeof(*buffer));
}

static dc_status make_buffer(dc_vk_sprite *r, VkDeviceSize bytes, VkBufferUsageFlags usage, host_buffer *out) {
    VkBufferCreateInfo create = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = bytes, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    VK_CHECK(vkCreateBuffer(r->device, &create, NULL, &out->buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(r->device, out->buffer, &requirements);
    uint32_t type;
    if (!memory_type(r, requirements.memoryTypeBits,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &type))
        return fail(r, DC_IO, "No coherent host-visible Vulkan memory");
    VkMemoryAllocateInfo allocate = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size, .memoryTypeIndex = type};
    VK_CHECK(vkAllocateMemory(r->device, &allocate, NULL, &out->memory));
    VK_CHECK(vkBindBufferMemory(r->device, out->buffer, out->memory, 0));
    VK_CHECK(vkMapMemory(r->device, out->memory, 0, bytes, 0, &out->mapped));
    out->bytes = bytes;
    return DC_OK;
}

static dc_status make_image(dc_vk_sprite *r, uint32_t width, uint32_t height, VkImageUsageFlags usage,
                             VkImage *image, VkDeviceMemory *memory, VkImageView *view) {
    VkImageCreateInfo create = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {width, height, 1}, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VK_CHECK(vkCreateImage(r->device, &create, NULL, image));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(r->device, *image, &requirements);
    uint32_t type;
    if (!memory_type(r, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &type) &&
        !memory_type(r, requirements.memoryTypeBits, 0, &type))
        return fail(r, DC_IO, "No compatible Vulkan image memory");
    VkMemoryAllocateInfo allocate = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size, .memoryTypeIndex = type};
    VK_CHECK(vkAllocateMemory(r->device, &allocate, NULL, memory));
    VK_CHECK(vkBindImageMemory(r->device, *image, *memory, 0));
    VkImageViewCreateInfo view_info = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = *image, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VK_CHECK(vkCreateImageView(r->device, &view_info, NULL, view));
    return DC_OK;
}

static dc_status make_depth_image(dc_vk_sprite *r, uint32_t width, uint32_t height,
                                  VkImage *image, VkDeviceMemory *memory, VkImageView *view) {
    VkImageCreateInfo create={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,.imageType=VK_IMAGE_TYPE_2D,
        .format=VK_FORMAT_D32_SFLOAT,.extent={width,height,1},.mipLevels=1,.arrayLayers=1,
        .samples=VK_SAMPLE_COUNT_1_BIT,.tiling=VK_IMAGE_TILING_OPTIMAL,
        .usage=VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,.sharingMode=VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout=VK_IMAGE_LAYOUT_UNDEFINED};
    VK_CHECK(vkCreateImage(r->device,&create,NULL,image));
    VkMemoryRequirements requirements;vkGetImageMemoryRequirements(r->device,*image,&requirements);
    uint32_t type;if(!memory_type(r,requirements.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,&type) &&
        !memory_type(r,requirements.memoryTypeBits,0,&type))return fail(r,DC_IO,"No compatible Vulkan depth memory");
    VkMemoryAllocateInfo allocate={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=requirements.size,.memoryTypeIndex=type};
    VK_CHECK(vkAllocateMemory(r->device,&allocate,NULL,memory));VK_CHECK(vkBindImageMemory(r->device,*image,*memory,0));
    VkImageViewCreateInfo view_info={.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,.image=*image,
        .viewType=VK_IMAGE_VIEW_TYPE_2D,.format=VK_FORMAT_D32_SFLOAT,
        .subresourceRange={VK_IMAGE_ASPECT_DEPTH_BIT,0,1,0,1}};
    VK_CHECK(vkCreateImageView(r->device,&view_info,NULL,view));return DC_OK;
}

static dc_status begin_commands(dc_vk_sprite *r) {
    VK_CHECK(vkResetCommandBuffer(r->command, 0));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    VK_CHECK(vkBeginCommandBuffer(r->command, &begin));
    return DC_OK;
}

static dc_status submit_commands(dc_vk_sprite *r) {
    VK_CHECK(vkEndCommandBuffer(r->command));
    VK_CHECK(vkResetFences(r->device, 1, &r->fence));
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1, .pCommandBuffers = &r->command};
    VkResult result = vkQueueSubmit(r->queue, 1, &submit, r->fence);
    if (result == VK_SUCCESS) result = vkWaitForFences(r->device, 1, &r->fence, VK_TRUE, 30000000000ull);
    if (result != VK_SUCCESS) {
        r->broken = 1;
        return vk_fail(r, result, "Vulkan command submission/completion");
    }
    return DC_OK;
}

static void drop_texture(dc_vk_sprite *r, texture *image) {
    if (image->sets[0]) vkFreeDescriptorSets(r->device, r->descriptor_pool, 2, image->sets);
    if (image->view) vkDestroyImageView(r->device, image->view, NULL);
    if (image->image) vkDestroyImage(r->device, image->image, NULL);
    if (image->memory) vkFreeMemory(r->device, image->memory, NULL);
    memset(image, 0, sizeof(*image));
}

void dc_vk_sprite_destroy(dc_vk_sprite *r) {
    if (!r) return;
    if (r->device) {
        vkDeviceWaitIdle(r->device);
        if (r->acquired) vkDestroySemaphore(r->device, r->acquired, NULL);
        if (r->rendered) vkDestroySemaphore(r->device, r->rendered, NULL);
        if (r->swapchain) vkDestroySwapchainKHR(r->device, r->swapchain, NULL);
        if (r->textures)
            for (uint32_t i = 0; i < r->max_textures; ++i) drop_texture(r, &r->textures[i]);
        for (uint32_t i = 0; i < 6; ++i)
            if (r->pipelines[i]) vkDestroyPipeline(r->device, r->pipelines[i], NULL);
        for (uint32_t i = 0; i < 2; ++i) {
            if (r->modules[i]) vkDestroyShaderModule(r->device, r->modules[i], NULL);
            if (r->samplers[i]) vkDestroySampler(r->device, r->samplers[i], NULL);
        }
        if (r->framebuffer) vkDestroyFramebuffer(r->device, r->framebuffer, NULL);
        if (r->render_pass) vkDestroyRenderPass(r->device, r->render_pass, NULL);
        if (r->pipeline_layout) vkDestroyPipelineLayout(r->device, r->pipeline_layout, NULL);
        if (r->descriptor_pool) vkDestroyDescriptorPool(r->device, r->descriptor_pool, NULL);
        if (r->descriptor_layout) vkDestroyDescriptorSetLayout(r->device, r->descriptor_layout, NULL);
        if (r->target_view) vkDestroyImageView(r->device, r->target_view, NULL);
        if (r->target) vkDestroyImage(r->device, r->target, NULL);
        if (r->target_memory) vkFreeMemory(r->device, r->target_memory, NULL);
        if (r->depth_view) vkDestroyImageView(r->device, r->depth_view, NULL);
        if (r->depth) vkDestroyImage(r->device, r->depth, NULL);
        if (r->depth_memory) vkFreeMemory(r->device, r->depth_memory, NULL);
        drop_buffer(r, &r->readback);
        drop_buffer(r, &r->vertices);
        if (r->fence) vkDestroyFence(r->device, r->fence, NULL);
        if (r->command_pool) vkDestroyCommandPool(r->device, r->command_pool, NULL);
        vkDestroyDevice(r->device, NULL);
    }
    if (r->debug && r->destroy_debug) r->destroy_debug(r->instance, r->debug, NULL);
    if (r->surface) vkDestroySurfaceKHR(r->instance, r->surface, NULL);
    if (r->instance) vkDestroyInstance(r->instance, NULL);
    free(r->textures);
    free(r->present_images);
    free(r);
}

static dc_status create_device(dc_vk_sprite *r, uint32_t validation, void *metal_layer) {
    uint32_t count = 0;
    VK_CHECK(vkEnumerateInstanceExtensionProperties(NULL, &count, NULL));
    if (count > 4096) return fail(r, DC_RANGE, "Too many instance extensions");
    VkExtensionProperties *available = calloc(count ? count : 1, sizeof(*available));
    if (!available) return DC_MEMORY;
    VkResult result = vkEnumerateInstanceExtensionProperties(NULL, &count, available);
    const char *extensions[4];
    uint32_t extension_count = 0;
#ifdef __APPLE__
    if (metal_layer) {
        if (!extension_present(available, count, VK_KHR_SURFACE_EXTENSION_NAME) ||
            !extension_present(available, count, VK_EXT_METAL_SURFACE_EXTENSION_NAME)) {
            free(available);
            return fail(r, DC_IO, "Vulkan Metal surface extensions unavailable");
        }
        extensions[extension_count++] = VK_KHR_SURFACE_EXTENSION_NAME;
        extensions[extension_count++] = VK_EXT_METAL_SURFACE_EXTENSION_NAME;
    }
#else
    if (metal_layer) { free(available); return fail(r, DC_ARGUMENT, "Metal layer requires Apple platform"); }
#endif
    VkInstanceCreateFlags flags = 0;
    if (result == VK_SUCCESS && extension_present(available, count, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        extensions[extension_count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    if (validation && result == VK_SUCCESS && extension_present(available, count, VK_EXT_DEBUG_UTILS_EXTENSION_NAME))
        extensions[extension_count++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    else if (validation) {
        free(available);
        return fail(r, DC_IO, "Debug-utils extension required for validation");
    }
    free(available);
    if (result != VK_SUCCESS) return vk_fail(r, result, "Enumerating instance extensions");
    const char *layer = "VK_LAYER_KHRONOS_validation";
    VkDebugUtilsMessengerCreateInfoEXT debug = {.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debug_message, .pUserData = r};
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "PortLab native sprites", .apiVersion = VK_API_VERSION_1_0};
    VkInstanceCreateInfo instance = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = validation ? &debug : NULL, .flags = flags, .pApplicationInfo = &app,
        .enabledExtensionCount = extension_count, .ppEnabledExtensionNames = extensions,
        .enabledLayerCount = validation ? 1u : 0u, .ppEnabledLayerNames = validation ? &layer : NULL};
    VK_CHECK(vkCreateInstance(&instance, NULL, &r->instance));
#ifdef __APPLE__
    if (metal_layer) {
        VkMetalSurfaceCreateInfoEXT surface = {.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
            .pLayer = metal_layer};
        PFN_vkCreateMetalSurfaceEXT create_surface = (PFN_vkCreateMetalSurfaceEXT)vkGetInstanceProcAddr(r->instance, "vkCreateMetalSurfaceEXT");
        if (!create_surface) return fail(r, DC_IO, "Missing Vulkan Metal surface entry point");
        VK_CHECK(create_surface(r->instance, &surface, NULL, &r->surface));
    }
#endif
    if (validation) {
        PFN_vkCreateDebugUtilsMessengerEXT create = (PFN_vkCreateDebugUtilsMessengerEXT)
            vkGetInstanceProcAddr(r->instance, "vkCreateDebugUtilsMessengerEXT");
        r->destroy_debug = (PFN_vkDestroyDebugUtilsMessengerEXT)
            vkGetInstanceProcAddr(r->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (!create || !r->destroy_debug) return fail(r, DC_IO, "Debug-utils entry points unavailable");
        VK_CHECK(create(r->instance, &debug, NULL, &r->debug));
    }
    VK_CHECK(vkEnumeratePhysicalDevices(r->instance, &count, NULL));
    if (!count || count > 64) return fail(r, DC_IO, "No admitted Vulkan physical devices");
    VkPhysicalDevice devices[64];
    VK_CHECK(vkEnumeratePhysicalDevices(r->instance, &count, devices));
    for (uint32_t i = 0; i < count && !r->physical; ++i) {
        uint32_t queues = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &queues, NULL);
        if (!queues || queues > 256) continue;
        VkQueueFamilyProperties properties[256];
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &queues, properties);
        for (uint32_t j = 0; j < queues; ++j) {
            VkBool32 present = VK_TRUE;
            if (r->surface) VK_CHECK(vkGetPhysicalDeviceSurfaceSupportKHR(devices[i], j, r->surface, &present));
            if (properties[j].queueCount && (properties[j].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                r->physical = devices[i]; r->queue_family = j; break;
            }
        }
    }
    if (!r->physical) return fail(r, DC_IO, "No Vulkan graphics queue");
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(r->physical, &properties);
    if (r->width > properties.limits.maxImageDimension2D || r->height > properties.limits.maxImageDimension2D)
        return fail(r, DC_RANGE, "Target exceeds Vulkan image limits");
    snprintf(r->info.device_name, sizeof(r->info.device_name), "%s", properties.deviceName);
    r->info.api_version = properties.apiVersion;
    r->info.driver_version = properties.driverVersion;
    r->info.device_type = properties.deviceType;
    vkGetPhysicalDeviceMemoryProperties(r->physical, &r->memory_properties);
    VkFormatProperties format;
    vkGetPhysicalDeviceFormatProperties(r->physical, VK_FORMAT_R8G8B8A8_UNORM, &format);
    VkFormatFeatureFlags required = VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
                                    VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    if ((format.optimalTilingFeatures & required) != required)
        return fail(r, DC_IO, "RGBA8 sprite format features unavailable");
    VK_CHECK(vkEnumerateDeviceExtensionProperties(r->physical, NULL, &count, NULL));
    if (count > 4096) return fail(r, DC_RANGE, "Too many device extensions");
    available = calloc(count ? count : 1, sizeof(*available));
    if (!available) return DC_MEMORY;
    result = vkEnumerateDeviceExtensionProperties(r->physical, NULL, &count, available);
    const char *subset = "VK_KHR_portability_subset";
    uint32_t portability = result == VK_SUCCESS && extension_present(available, count, subset);
    uint32_t swapchain = result == VK_SUCCESS && extension_present(available, count, VK_KHR_SWAPCHAIN_EXTENSION_NAME);
    free(available);
    if (result != VK_SUCCESS) return vk_fail(r, result, "Enumerating device extensions");
    if (r->surface && !swapchain) return fail(r, DC_IO, "Vulkan swapchain extension unavailable");
    const char *device_extensions[2];
    uint32_t device_extension_count = 0;
    if (portability) device_extensions[device_extension_count++] = subset;
    if (r->surface) device_extensions[device_extension_count++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    float priority = 1;
    VkDeviceQueueCreateInfo queue = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = r->queue_family, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo device = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue,
        .enabledExtensionCount = device_extension_count, .ppEnabledExtensionNames = device_extensions};
    VK_CHECK(vkCreateDevice(r->physical, &device, NULL, &r->device));
    vkGetDeviceQueue(r->device, r->queue_family, 0, &r->queue);
    return DC_OK;
}

static dc_status create_swapchain_impl(dc_vk_sprite *r) {
    VkSurfaceCapabilitiesKHR caps;
    VK_CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(r->physical, r->surface, &caps));
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT))
        return fail(r, DC_IO, "Surface does not support Vulkan transfer destination");
    uint32_t count = 0;
    VK_CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(r->physical, r->surface, &count, NULL));
    if (!count || count > 256) return fail(r, DC_IO, "No admitted Vulkan surface formats");
    VkSurfaceFormatKHR formats[256], format = {VK_FORMAT_UNDEFINED, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
    VK_CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(r->physical, r->surface, &count, formats));
    for (uint32_t i = 0; i < count; ++i) {
        if (formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR &&
            (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM || formats[i].format == VK_FORMAT_R8G8B8A8_UNORM)) {
            format = formats[i]; break;
        }
    }
    if (count == 1 && formats[0].format == VK_FORMAT_UNDEFINED) format.format = VK_FORMAT_B8G8R8A8_UNORM;
    if (format.format == VK_FORMAT_UNDEFINED) return fail(r, DC_IO, "Surface requires unsupported pixel encoding");
    VkFormatProperties source, destination;
    vkGetPhysicalDeviceFormatProperties(r->physical, VK_FORMAT_R8G8B8A8_UNORM, &source);
    vkGetPhysicalDeviceFormatProperties(r->physical, format.format, &destination);
    if (!(source.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_SRC_BIT) ||
        !(destination.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_DST_BIT))
        return fail(r, DC_IO, "Surface format lacks Vulkan blit support");
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = r->width; extent.height = r->height;
        if (extent.width < caps.minImageExtent.width) extent.width = caps.minImageExtent.width;
        if (extent.height < caps.minImageExtent.height) extent.height = caps.minImageExtent.height;
        if (extent.width > caps.maxImageExtent.width) extent.width = caps.maxImageExtent.width;
        if (extent.height > caps.maxImageExtent.height) extent.height = caps.maxImageExtent.height;
    }
    if (!extent.width || !extent.height) return fail(r, DC_IO, "Surface is not currently drawable");
    uint32_t images = caps.minImageCount + 1;
    if (caps.maxImageCount && images > caps.maxImageCount) images = caps.maxImageCount;
    VkCompositeAlphaFlagBitsKHR alpha;
    if (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR) alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    else if (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR) alpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    else return fail(r, DC_IO, "Surface requires unsupported alpha composition");
    if (r->swapchain) vkDestroySwapchainKHR(r->device, r->swapchain, NULL);
    r->swapchain = VK_NULL_HANDLE;
    free(r->present_images); r->present_images = NULL; r->present_count = 0;
    VkSwapchainCreateInfoKHR create = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = r->surface, .minImageCount = images, .imageFormat = format.format, .imageColorSpace = format.colorSpace,
        .imageExtent = extent, .imageArrayLayers = 1, .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = caps.currentTransform,
        .compositeAlpha = alpha, .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE};
    VK_CHECK(vkCreateSwapchainKHR(r->device, &create, NULL, &r->swapchain));
    VK_CHECK(vkGetSwapchainImagesKHR(r->device, r->swapchain, &r->present_count, NULL));
    if (!r->present_count || r->present_count > 64) return fail(r, DC_RANGE, "Unsupported Vulkan swapchain image count");
    r->present_images = calloc(r->present_count, sizeof(*r->present_images));
    if (!r->present_images) return DC_MEMORY;
    VK_CHECK(vkGetSwapchainImagesKHR(r->device, r->swapchain, &r->present_count, r->present_images));
    r->present_extent = extent;
    return DC_OK;
}

#ifdef __APPLE__
typedef struct swapchain_request { dc_vk_sprite *renderer; dc_status status; } swapchain_request;
static void create_swapchain_main(void *context) {
    swapchain_request *request = context;
    request->status = create_swapchain_impl(request->renderer);
}
#endif

static dc_status create_swapchain(dc_vk_sprite *r) {
    /* Drain Vulkan work on the caller's thread before touching the layer. */
    VK_CHECK(vkDeviceWaitIdle(r->device));
#ifdef __APPLE__
    /* MoltenVK updates CAMetalLayer properties during vkCreateSwapchainKHR.
     * UIKit requires those layer changes on the main thread. Rendering and
     * queue waits remain on the serialized Vulkan worker. */
    if (!pthread_main_np()) {
        swapchain_request request = {r, DC_IO};
        dispatch_sync_f(dispatch_get_main_queue(), &request, create_swapchain_main);
        return request.status;
    }
#endif
    return create_swapchain_impl(r);
}

static dc_status present_target(dc_vk_sprite *r) {
    uint32_t index = 0;
    VkResult result = vkAcquireNextImageKHR(r->device, r->swapchain, 1000000000ull, r->acquired, VK_NULL_HANDLE, &index);
    if (result == VK_ERROR_OUT_OF_DATE_KHR) {
        dc_status status = create_swapchain(r);
        if (status != DC_OK) return status;
        result = vkAcquireNextImageKHR(r->device, r->swapchain, 1000000000ull, r->acquired, VK_NULL_HANDLE, &index);
    }
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return vk_fail(r, result, "Acquiring surface image");
    /* After acquisition, any failure requires recreation to retire the semaphore. */
    dc_status status = begin_commands(r);
    if (status != DC_OK) { r->broken = 1; return status; }
    VkImageMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = r->present_images[index],
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(r->command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    VkImageBlit blit = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .srcOffsets = {{0,0,0}, {(int32_t)r->width,(int32_t)r->height,1}},
        .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .dstOffsets = {{0,0,0}, {(int32_t)r->present_extent.width,(int32_t)r->present_extent.height,1}}};
    vkCmdBlitImage(r->command, r->target, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        r->present_images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, VK_FILTER_NEAREST);
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = 0;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(r->command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    result = vkEndCommandBuffer(r->command);
    VkPipelineStageFlags wait = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1,
        .pWaitSemaphores = &r->acquired, .pWaitDstStageMask = &wait, .commandBufferCount = 1,
        .pCommandBuffers = &r->command, .signalSemaphoreCount = 1, .pSignalSemaphores = &r->rendered};
    if (result == VK_SUCCESS) result = vkQueueSubmit(r->queue, 1, &submit, VK_NULL_HANDLE);
    if (result != VK_SUCCESS) { r->broken = 1; return vk_fail(r, result, "Submitting surface blit"); }
    VkPresentInfoKHR present = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &r->rendered, .swapchainCount = 1,
        .pSwapchains = &r->swapchain, .pImageIndices = &index};
    result = vkQueuePresentKHR(r->queue, &present);
    VkResult idle = vkQueueWaitIdle(r->queue);
    if (idle != VK_SUCCESS) { r->broken = 1; return vk_fail(r, idle, "Completing surface presentation"); }
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) return create_swapchain(r);
    if (result != VK_SUCCESS) { r->broken = 1; return vk_fail(r, result, "Presenting surface image"); }
    return DC_OK;
}

static dc_status create_resources(dc_vk_sprite *r, const dc_vk_sprite_config *config) {
    VkCommandPoolCreateInfo pool = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = r->queue_family};
    VK_CHECK(vkCreateCommandPool(r->device, &pool, NULL, &r->command_pool));
    VkCommandBufferAllocateInfo command = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = r->command_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VK_CHECK(vkAllocateCommandBuffers(r->device, &command, &r->command));
    VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VK_CHECK(vkCreateFence(r->device, &fence, NULL, &r->fence));
    if (r->surface) {
        VkSemaphoreCreateInfo semaphore = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        VK_CHECK(vkCreateSemaphore(r->device, &semaphore, NULL, &r->acquired));
        VK_CHECK(vkCreateSemaphore(r->device, &semaphore, NULL, &r->rendered));
        dc_status surface_status = create_swapchain(r);
        if (surface_status != DC_OK) return surface_status;
    }
    dc_status status = make_image(r, r->width, r->height,
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        &r->target, &r->target_memory, &r->target_view);
    if (status != DC_OK) return status;
    status = make_depth_image(r,r->width,r->height,&r->depth,&r->depth_memory,&r->depth_view);
    if (status != DC_OK) return status;
    status = make_buffer(r, (VkDeviceSize)r->width * r->height * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &r->readback);
    if (status != DC_OK) return status;
    VkAttachmentDescription attachments[2] = {{.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL},
        {.format = VK_FORMAT_D32_SFLOAT, .samples = VK_SAMPLE_COUNT_1_BIT,
         .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
         .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
         .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL}};
    VkAttachmentReference reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkAttachmentReference depth_reference = {1,VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &reference,.pDepthStencilAttachment=&depth_reference};
    VkSubpassDependency dependencies[2] = {
        {.srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0,
         .srcStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT, .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
         .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT},
        {.srcSubpass = 0, .dstSubpass = VK_SUBPASS_EXTERNAL,
         .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
         .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT}};
    VkRenderPassCreateInfo pass = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 2, .pAttachments = attachments, .subpassCount = 1, .pSubpasses = &subpass,
        .dependencyCount = 2, .pDependencies = dependencies};
    VK_CHECK(vkCreateRenderPass(r->device, &pass, NULL, &r->render_pass));
    VkImageView framebuffer_views[2] = {r->target_view,r->depth_view};
    VkFramebufferCreateInfo framebuffer = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = r->render_pass, .attachmentCount = 2, .pAttachments = framebuffer_views,
        .width = r->width, .height = r->height, .layers = 1};
    VK_CHECK(vkCreateFramebuffer(r->device, &framebuffer, NULL, &r->framebuffer));
    VkDescriptorSetLayoutBinding binding = {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo layout = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1, .pBindings = &binding};
    VK_CHECK(vkCreateDescriptorSetLayout(r->device, &layout, NULL, &r->descriptor_layout));
    VkDescriptorPoolSize size = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2 * r->max_textures};
    VkDescriptorPoolCreateInfo descriptors = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT, .maxSets = size.descriptorCount,
        .poolSizeCount = 1, .pPoolSizes = &size};
    VK_CHECK(vkCreateDescriptorPool(r->device, &descriptors, NULL, &r->descriptor_pool));
    VkPushConstantRange push = {VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16};
    VkPipelineLayoutCreateInfo pipeline_layout = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &r->descriptor_layout, .pushConstantRangeCount = 1, .pPushConstantRanges = &push};
    VK_CHECK(vkCreatePipelineLayout(r->device, &pipeline_layout, NULL, &r->pipeline_layout));
    for (uint32_t i = 0; i < 2; ++i) {
        VkSamplerCreateInfo sampler = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = i ? VK_FILTER_LINEAR : VK_FILTER_NEAREST, .minFilter = i ? VK_FILTER_LINEAR : VK_FILTER_NEAREST,
            .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT, .addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT, .maxLod = 0};
        VK_CHECK(vkCreateSampler(r->device, &sampler, NULL, &r->samplers[i]));
        VkShaderModuleCreateInfo module = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = i ? config->fragment_spirv_bytes : config->vertex_spirv_bytes,
            .pCode = i ? config->fragment_spirv : config->vertex_spirv};
        VK_CHECK(vkCreateShaderModule(r->device, &module, NULL, &r->modules[i]));
    }
    VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
         .module = r->modules[0], .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
         .module = r->modules[1], .pName = "main"}};
    VkVertexInputBindingDescription vertex_binding = {0, sizeof(dc_sprite_vertex), VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attributes[3] = {
        {0, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(dc_sprite_vertex, x)},
        {1, 0, VK_FORMAT_R32_UINT, offsetof(dc_sprite_vertex, diffuse)},
        {2, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(dc_sprite_vertex, u)}};
    VkPipelineVertexInputStateCreateInfo input = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &vertex_binding,
        .vertexAttributeDescriptionCount = 3, .pVertexAttributeDescriptions = attributes};
    VkPipelineInputAssemblyStateCreateInfo assembly = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, .primitiveRestartEnable = VK_TRUE};
    /* Sprite strips are non-indexed; enabling restart admits Metal portability
     * devices that cannot disable it for strips. Triangle lists disable it. */
    VkViewport viewport = {0, 0, (float)r->width, (float)r->height, 0, 1};
    VkRect2D scissor = {{0, 0}, {r->width, r->height}};
    VkPipelineViewportStateCreateInfo view = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor};
    VkDynamicState dynamic_scissor=VK_DYNAMIC_STATE_SCISSOR;
    VkPipelineDynamicStateCreateInfo dynamic={.sType=VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount=1,.pDynamicStates=&dynamic_scissor};
    VkPipelineRasterizationStateCreateInfo raster = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1};
    VkPipelineMultisampleStateCreateInfo samples = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
    VkPipelineDepthStencilStateCreateInfo depth = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = VK_TRUE, .depthWriteEnable = VK_TRUE, .depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL};
    const VkBlendFactor sources[] = {VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ZERO};
    const VkBlendFactor destinations[] = {VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_SRC_COLOR};
    for (uint32_t i = 0; i < 6; ++i) {
        uint32_t blend_index = i % 3;
        assembly.topology = i < 3 ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        assembly.primitiveRestartEnable = i < 3;
        VkPipelineColorBlendAttachmentState blend = {.blendEnable = VK_TRUE,
            .srcColorBlendFactor = sources[blend_index], .dstColorBlendFactor = destinations[blend_index], .colorBlendOp = VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = sources[blend_index],
            .dstAlphaBlendFactor = blend_index == 2 ? VK_BLEND_FACTOR_SRC_ALPHA : destinations[blend_index],
            .alphaBlendOp = VK_BLEND_OP_ADD, .colorWriteMask = 15};
        VkPipelineColorBlendStateCreateInfo blending = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1, .pAttachments = &blend};
        VkGraphicsPipelineCreateInfo pipeline = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = 2, .pStages = stages, .pVertexInputState = &input, .pInputAssemblyState = &assembly,
            .pViewportState = &view, .pRasterizationState = &raster, .pMultisampleState = &samples,
            .pDepthStencilState = &depth, .pColorBlendState = &blending,.pDynamicState=&dynamic, .layout = r->pipeline_layout, .renderPass = r->render_pass};
        VK_CHECK(vkCreateGraphicsPipelines(r->device, VK_NULL_HANDLE, 1, &pipeline, NULL, &r->pipelines[i]));
    }
    return DC_OK;
}

dc_status dc_vk_sprite_create(const dc_vk_sprite_config *config, dc_vk_sprite **out, char *error, size_t capacity) {
#if TARGET_OS_SIMULATOR
    /* iOS Simulator's SimMetalHost currently crashes while servicing
     * MTLSimArgumentEncoder texture updates. MoltenVK's documented fallback
     * binds descriptor resources without Metal argument buffers. Keep device
     * builds on the default, faster argument-buffer path. */
    if (!getenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"))
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 0);
#endif
    if (out) *out = NULL;
    if (!config || !out || !config->width || !config->height || config->width > 4096 || config->height > 4096 ||
        !config->max_textures || config->max_textures > 4096 || config->initial_filter < 1 || config->initial_filter > 2 ||
        !config->vertex_spirv || !config->fragment_spirv || config->vertex_spirv_bytes < 20 ||
        config->fragment_spirv_bytes < 20 || config->vertex_spirv_bytes % 4 || config->fragment_spirv_bytes % 4 ||
        (uintptr_t)config->vertex_spirv % 4 || (uintptr_t)config->fragment_spirv % 4 ||
        config->vertex_spirv[0] != 0x07230203 || config->fragment_spirv[0] != 0x07230203) {
        if (error && capacity) snprintf(error, capacity, "Invalid Vulkan sprite configuration");
        return DC_ARGUMENT;
    }
    dc_vk_sprite *r = calloc(1, sizeof(*r));
    if (!r) return DC_MEMORY;
    r->width = config->width; r->height = config->height;
    r->max_textures = config->max_textures; r->initial_filter = config->initial_filter;
    r->next_texture = 1;
    r->textures = calloc(r->max_textures, sizeof(*r->textures));
    dc_status status = r->textures ? create_device(r, config->validation, config->metal_layer) : DC_MEMORY;
    if (status == DC_OK) status = create_resources(r, config);
    if (status != DC_OK) {
        if (error && capacity) snprintf(error, capacity, "%s", r->error[0] ? r->error : "Vulkan sprite allocation failed");
        dc_vk_sprite_destroy(r);
        return status;
    }
    if (error && capacity) error[0] = 0;
    *out = r;
    return DC_OK;
}

const char *dc_vk_sprite_error(const dc_vk_sprite *r) { return r ? r->error : "No renderer"; }

dc_status dc_vk_sprite_get_info(const dc_vk_sprite *r, dc_vk_sprite_info *out) {
    if (!r || !out) return DC_ARGUMENT;
    *out = r->info;
    return DC_OK;
}

static texture *find_texture(dc_vk_sprite *r, uintptr_t id) {
    if (id) for (uint32_t i = 0; i < r->max_textures; ++i)
        if (r->textures[i].id == id) return &r->textures[i];
    return NULL;
}

dc_status dc_vk_sprite_upload(dc_vk_sprite *r, uint32_t width, uint32_t height,
        const uint8_t *rgba, size_t bytes, uintptr_t *handle) {
    if (!r || !rgba || !handle) return DC_ARGUMENT;
    if (r->broken) return fail(r, DC_IO, "Renderer requires recreation after submission failure");
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(r->physical, &properties);
    if (!width || !height || width > 4096 || height > 4096 || width > properties.limits.maxImageDimension2D ||
        height > properties.limits.maxImageDimension2D || bytes != (size_t)width * height * 4)
        return fail(r, DC_RANGE, "Invalid texture dimensions or byte count");
    texture *slot = NULL;
    for (uint32_t i = 0; i < r->max_textures; ++i) if (!r->textures[i].id) { slot = &r->textures[i]; break; }
    if (!slot || !r->next_texture) return fail(r, DC_RANGE, "Texture handle capacity exhausted");
    host_buffer staging = {0};
    dc_status status = make_buffer(r, bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &staging);
    if (status == DC_OK) status = make_image(r, width, height,
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, &slot->image, &slot->memory, &slot->view);
    if (status == DC_OK) {
        memcpy(staging.mapped, rgba, bytes);
        status = begin_commands(r);
    }
    if (status == DC_OK) {
        VkImageMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->image, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
        vkCmdPipelineBarrier(r->command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, NULL, 0, NULL, 1, &barrier);
        VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {width, height, 1}};
        vkCmdCopyBufferToImage(r->command, staging.buffer, slot->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        vkCmdPipelineBarrier(r->command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, NULL, 0, NULL, 1, &barrier);
        status = submit_commands(r);
    }
    /* A timed-out queue can still reference staging and image resources. */
    if (r->broken) vkDeviceWaitIdle(r->device);
    drop_buffer(r, &staging);
    if (status == DC_OK) {
        VkDescriptorSetLayout layouts[2] = {r->descriptor_layout, r->descriptor_layout};
        VkDescriptorSetAllocateInfo allocate = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = r->descriptor_pool, .descriptorSetCount = 2, .pSetLayouts = layouts};
        VkResult result = vkAllocateDescriptorSets(r->device, &allocate, slot->sets);
        if (result != VK_SUCCESS) { memset(slot->sets, 0, sizeof(slot->sets)); status = vk_fail(r, result, "Allocating texture descriptors"); }
    }
    if (status != DC_OK) { drop_texture(r, slot); return status; }
    for (uint32_t i = 0; i < 2; ++i) {
        VkDescriptorImageInfo image = {r->samplers[i], slot->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
        VkWriteDescriptorSet write = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = slot->sets[i], .dstBinding = 0, .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &image};
        vkUpdateDescriptorSets(r->device, 1, &write, 0, NULL);
    }
    slot->opaque = 1;
    for (size_t i = 3; i < bytes; i += 4) if (rgba[i] != 255) { slot->opaque = 0; break; }
    slot->id = r->next_texture++;
    *handle = slot->id;
    return DC_OK;
}

dc_status dc_vk_sprite_remove_texture(dc_vk_sprite *r, uintptr_t handle) {
    if (!r) return DC_ARGUMENT;
    if (r->broken) return fail(r, DC_IO, "Renderer requires recreation after submission failure");
    texture *image = find_texture(r, handle);
    if (!image) return fail(r, DC_ARGUMENT, "Unknown or stale texture handle");
    drop_texture(r, image);
    return DC_OK;
}

/* State interpretation is ordered, including post-draw filter restoration.
 * No native command is silently discarded except software VP: XYZRHW vertices
 * are already transformed, so the supported profile has no vertex processing. */
typedef struct sprite_state {
    uintptr_t render[29], stage[7], sampler[8], texture, stream;
    uint32_t fvf;
} sprite_state;

static dc_status interpret(dc_vk_sprite *r, const dc_sprite_plan *plan, sprite_state *s,
        uintptr_t vertex_token, prepared_draw *draw) {
    for (uint32_t i = 0; i < plan->count; ++i) {
        const dc_sprite_command *c = &plan->commands[i];
        const uintptr_t *a = c->arguments;
        switch (c->kind) {
        case DC_SPRITE_RENDER_STATE:
            if (a[0] != 14 && a[0] != 19 && a[0] != 20 && a[0] != 27 && a[0] != 28) goto unsupported;
            s->render[a[0]] = a[1]; break;
        case DC_SPRITE_TEXTURE_STAGE:
            if (a[0] || !a[1] || a[1] > 6) goto unsupported;
            s->stage[a[1]] = a[2]; break;
        case DC_SPRITE_SAMPLER_STATE:
            if (a[0] || a[1] < 5 || a[1] > 7) goto unsupported;
            s->sampler[a[1]] = a[2]; break;
        case DC_SPRITE_SOFTWARE_VERTEX: break;
        case DC_SPRITE_TEXTURE:
            if (a[0]) goto unsupported;
            s->texture = a[1]; break;
        case DC_SPRITE_VERTEX_STREAM:
            if (a[0] || a[2] || a[3] != sizeof(dc_sprite_vertex)) goto unsupported;
            s->stream = a[1]; break;
        case DC_SPRITE_VERTEX_FORMAT: s->fvf = (uint32_t)a[0]; break;
        case DC_SPRITE_DRAW:
            if (!draw || a[0] != 5 || a[1] || a[2] != 2 || s->stream != vertex_token || s->fvf != 0x1c4 ||
                s->render[14] || s->render[28] || s->render[27] != 1 ||
                s->stage[1] != 4 || s->stage[2] != 2 || s->stage[3] > 1 ||
                s->sampler[7] || s->sampler[5] < 1 || s->sampler[5] > 2 || s->sampler[5] != s->sampler[6]) goto unsupported;
            draw->image = find_texture(r, s->texture);
            if (!draw->image) return fail(r, DC_ARGUMENT, "Unknown or stale draw texture handle");
            draw->filter = (uint32_t)s->sampler[5] - 1;
            draw->alpha_op = (uint32_t)s->stage[4];
            if (draw->alpha_op == 1) {
                if (!draw->image->opaque || (draw->vertices[0].diffuse >> 24) != 255)
                    return fail(r, DC_FORMAT, "Alpha-op DISABLE requires opaque texture and diffuse in this profile");
            } else if (draw->alpha_op != 4 || s->stage[5] != 2 || s->stage[6] > 1) goto unsupported;
            if (s->render[19] == 5 && s->render[20] == 6) draw->pipeline = 0;
            else if (s->render[19] == 5 && s->render[20] == 2) draw->pipeline = 1;
            else if (s->render[19] == 1 && s->render[20] == 4) draw->pipeline = 2;
            else goto unsupported;
            break;
        default: goto unsupported;
        }
    }
    return DC_OK;
unsupported:
    return fail(r, DC_FORMAT, "Unsupported native sprite command/effective state");
}

static dc_status render_prepared(dc_vk_sprite *r, prepared_draw *draws, size_t visible,
    const uint8_t clear[4], uint8_t *rgba,const dc_vk_clip_rect *clip);

dc_status dc_vk_sprite_render(dc_vk_sprite *r, const dc_vk_sprite_item *items, size_t count,
        const uint8_t clear[4], uint8_t *rgba, size_t capacity) {
    if (!r || !clear || (!rgba && capacity) || (count && !items)) return DC_ARGUMENT;
    if (r->broken) return fail(r, DC_IO, "Renderer requires recreation after submission failure");
    if (count > 4096 || (rgba && capacity < (size_t)r->width * r->height * 4))
        return fail(r, DC_RANGE, "Frame item count or output capacity out of range");
    prepared_draw *draws = calloc(count ? count : 1, sizeof(*draws));
    if (!draws) return DC_MEMORY;
    size_t visible = 0;
    sprite_state state = {0};
    state.sampler[5] = state.sampler[6] = r->initial_filter;
    dc_sprite_plan plan;
    dc_status status = dc_sprite_begin_plan(&plan);
    if (status == DC_OK) status = interpret(r, &plan, &state, 0, NULL);
    uint32_t mode = plan.next_mode;
    for (size_t i = 0; i < count && status == DC_OK; ++i) {
        if (items[i].hidden == 1) continue;
        prepared_draw *draw = &draws[visible];
        draw->source = draw->vertices; draw->count = 4;
        status = dc_sprite_build_vertices(&items[i].pose, draw->vertices);
        if (status != DC_OK) { fail(r, status, "Invalid sprite pose at item %zu", i); break; }
        dc_sprite_draw input = {.vertex_buffer = i + 1, .texture = items[i].texture,
            .blend_mode = items[i].blend_mode, .point_filter = items[i].point_filter,
            .software_vertex = items[i].software_vertex};
        status = dc_sprite_build_plan(&input, mode, &plan);
        if (status != DC_OK) { fail(r, status, "Invalid sprite draw mode at item %zu", i); break; }
        status = interpret(r, &plan, &state, i + 1, draw);
        mode = plan.next_mode;
        ++visible;
    }
    if (status != DC_OK) { free(draws); return status; }
    status = render_prepared(r, draws, visible, clear, rgba,NULL);
    free(draws);
    return status;
}

dc_status dc_vk_geometry_render(dc_vk_sprite *r, const dc_vk_geometry_item *items, size_t count,
        const uint8_t clear[4], uint8_t *rgba, size_t capacity) {
    return dc_vk_geometry_render_region(r,items,count,clear,rgba,capacity,NULL);
}
dc_status dc_vk_geometry_render_region(dc_vk_sprite *r,const dc_vk_geometry_item *items,size_t count,
        const uint8_t clear[4],uint8_t *rgba,size_t capacity,const dc_vk_clip_rect *clip) {
    if (!r || !clear || (!rgba && capacity) || (count && !items)) return DC_ARGUMENT;
    if (r->broken) return fail(r, DC_IO, "Renderer requires recreation after submission failure");
    if (count > 4096 || (rgba && capacity < (size_t)r->width * r->height * 4)) return DC_RANGE;
    if (clip && (!clip->width || !clip->height || clip->x>r->width || clip->y>r->height ||
        clip->width>r->width-clip->x || clip->height>r->height-clip->y)) return DC_RANGE;
    prepared_draw *draws = calloc(count ? count : 1, sizeof(*draws));
    if (!draws) return DC_MEMORY;
    size_t visible = 0, total = 0;
    dc_status status = DC_OK;
    for (size_t i = 0; i < count; ++i) {
        const dc_vk_geometry_item *item = &items[i];
        if (item->hidden == 1) continue;
        if (!item->vertices || !item->vertex_count || item->vertex_count % 3 || item->vertex_count > 1048576 - total) {
            status = DC_RANGE; break;
        }
        if (item->blend_mode > 3 || item->point_filter > 1) { status = DC_FORMAT; break; }
        texture *image = find_texture(r, item->texture);
        if (!image) { status = DC_ARGUMENT; break; }
        for (size_t j = 0; j < item->vertex_count; ++j) {
            const dc_sprite_vertex *v = &item->vertices[j];
            if (!isfinite(v->x) || !isfinite(v->y) || !isfinite(v->z) ||
                !isfinite(v->rhw) || v->rhw <= 0 || !isfinite(v->u) || !isfinite(v->v)) { status = DC_FORMAT; break; }
        }
        if (status != DC_OK) break;
        uint32_t blend = item->blend_mode == 1 ? 1 : item->blend_mode == 2 ? 2 : 0;
        draws[visible++] = (prepared_draw){.source = item->vertices, .count = item->vertex_count,
            .image = image, .pipeline = 3 + blend, .filter = item->point_filter ? 0 : 1, .alpha_op = 4};
        total += item->vertex_count;
    }
    if (status == DC_OK) status = render_prepared(r, draws, visible, clear, rgba,clip);
    free(draws);
    return status;
}

static dc_status render_prepared(dc_vk_sprite *r, prepared_draw *draws, size_t visible,
        const uint8_t clear[4], uint8_t *rgba,const dc_vk_clip_rect *clip) {
    dc_status status = DC_OK;
    VkDeviceSize vertex_bytes = 0;
    for (size_t i = 0; i < visible; ++i) {
        draws[i].offset = vertex_bytes;
        vertex_bytes += draws[i].count * sizeof(dc_sprite_vertex);
    }
    if (vertex_bytes > r->vertices.bytes) {
        drop_buffer(r, &r->vertices);
        status = make_buffer(r, vertex_bytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &r->vertices);
    }
    if (status == DC_OK) {
        for (size_t i = 0; i < visible; ++i)
            memcpy((uint8_t *)r->vertices.mapped + draws[i].offset, draws[i].source, draws[i].count * sizeof(dc_sprite_vertex));
        status = begin_commands(r);
    }
    if (status == DC_OK) {
        VkClearValue clear_values[2] = {{0},{0}};
        for (uint32_t i = 0; i < 4; ++i) clear_values[0].color.float32[i] = clear[i] / 255.0f;
        clear_values[1].depthStencil.depth = 1.0f;
        VkRenderPassBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = r->render_pass, .framebuffer = r->framebuffer,
            .renderArea = {{0, 0}, {r->width, r->height}}, .clearValueCount = 2, .pClearValues = clear_values};
        vkCmdBeginRenderPass(r->command, &begin, VK_SUBPASS_CONTENTS_INLINE);
        VkRect2D scissor={{0,0},{r->width,r->height}};
        if (clip) scissor=(VkRect2D){{(int32_t)clip->x,(int32_t)clip->y},{clip->width,clip->height}};
        vkCmdSetScissor(r->command,0,1,&scissor);
        for (size_t i = 0; i < visible; ++i) {
            prepared_draw *draw = &draws[i];
            struct { float width, height; uint32_t alpha_op, reserved; } push = {(float)r->width, (float)r->height, draw->alpha_op, 0};
            VkDeviceSize offset = draw->offset;
            vkCmdBindPipeline(r->command, VK_PIPELINE_BIND_POINT_GRAPHICS, r->pipelines[draw->pipeline]);
            vkCmdBindDescriptorSets(r->command, VK_PIPELINE_BIND_POINT_GRAPHICS, r->pipeline_layout,
                0, 1, &draw->image->sets[draw->filter], 0, NULL);
            vkCmdBindVertexBuffers(r->command, 0, 1, &r->vertices.buffer, &offset);
            vkCmdPushConstants(r->command, r->pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                0, sizeof(push), &push);
            vkCmdDraw(r->command, (uint32_t)draw->count, 1, 0, 0);
        }
        vkCmdEndRenderPass(r->command);
        if (rgba) {
            VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                .imageExtent = {r->width, r->height, 1}};
            vkCmdCopyImageToBuffer(r->command, r->target, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, r->readback.buffer, 1, &copy);
            VkBufferMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
                .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .buffer = r->readback.buffer, .size = VK_WHOLE_SIZE};
            vkCmdPipelineBarrier(r->command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                0, 0, NULL, 1, &barrier, 0, NULL);
        }
        status = submit_commands(r);
        if (status == DC_OK && r->surface) status = present_target(r);
        if (status == DC_OK) {
            if (rgba) memcpy(rgba, r->readback.mapped, (size_t)r->width * r->height * 4);
            ++r->info.submitted_frames;
        }
    }
    return status;
}
