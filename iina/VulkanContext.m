//
//  VulkanContext.m
//  iina
//
//  See VulkanContext.h for the design.
//

// VK_USE_PLATFORM_METAL_EXT declares VK_EXT_metal_objects (Vulkan objects
// exported as Metal objects). VK_ENABLE_BETA_EXTENSIONS declares
// VK_KHR_portability_subset, which MoltenVK has and which a device must enable
// when the GPU offers it.
#define VK_USE_PLATFORM_METAL_EXT 1
#define VK_ENABLE_BETA_EXTENSIONS 1

#import "VulkanContext.h"

#import <CoreImage/CoreImage.h>
#include <vulkan/vulkan.h>
#include <mpv/render_vk.h>

NSString * const VulkanRenderAPIType = @MPV_RENDER_API_TYPE_VULKAN;

/// The Vulkan version that IINA asks for. libplacebo needs at least 1.2, and
/// MoltenVK 1.4.2 offers 1.4.
static const uint32_t kApiVersion = VK_API_VERSION_1_3;

/// 10 bits per color channel. MoltenVK maps it to MTLPixelFormatRGB10A2Unorm,
/// which CAMetalLayer accepts, also for HDR10 output.
static const VkFormat kImageFormat = VK_FORMAT_A2B10G10R10_UNORM_PACK32;

/// The number of render images. Two let mpv render one frame while Metal copies the other.
enum { kImageCount = 2 };

/// The device extensions that IINA enables if MoltenVK has them. These are the
/// extensions that libplacebo recommends (pl_vulkan_recommended_extensions),
/// without those that need VK_KHR_swapchain, because IINA has no swapchain.
static const char * const kOptionalExtensions[] = {
  VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME,
  VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME,
  VK_EXT_PCI_BUS_INFO_EXTENSION_NAME,
  VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
  VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
  VK_KHR_FORMAT_FEATURE_FLAGS_2_EXTENSION_NAME,
  VK_EXT_HOST_IMAGE_COPY_EXTENSION_NAME,
  VK_KHR_MAINTENANCE_4_EXTENSION_NAME,
};
enum { kMaxExtensions = 16 };

/// One image that mpv renders into.
typedef struct {
  VkImage image;
  VkDeviceMemory memory;
  /// The layout that mpv left the image in.
  VkImageLayout layout;
  /// The value of the `present` semaphore after Metal last finished reading this
  /// image. mpv waits for this value before it renders into the image again.
  uint64_t releaseValue;
} RenderImage;

static NSError *makeError(NSString *message) {
  return [NSError errorWithDomain:@"com.colliderli.iina.vulkan" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation VulkanContext {
  VkInstance _instance;
  VkPhysicalDevice _physicalDevice;
  VkDevice _device;
  uint32_t _queueFamily;

  // Extensions and features that are enabled on _device. mpv reads them until
  // the render context is freed, so they live as long as this object.
  const char *_extensions[kMaxExtensions];
  int _extensionCount;
  VkPhysicalDeviceFeatures2 _features;
  VkPhysicalDeviceVulkan11Features _features11;
  VkPhysicalDeviceVulkan12Features _features12;
  VkPhysicalDeviceVulkan13Features _features13;
  VkPhysicalDevicePortabilitySubsetFeaturesKHR _portabilityFeatures;

  PFN_vkExportMetalObjectsEXT _exportMetalObjects;

  // Timeline semaphores (a semaphore that holds a counter, so that one
  // semaphore can mark many frames). mpv signals `render` when a frame is
  // done; Metal signals `present` when it has copied a frame.
  VkSemaphore _renderSemaphore;
  VkSemaphore _presentSemaphore;
  id<MTLSharedEvent> _renderEvent;
  id<MTLSharedEvent> _presentEvent;
  uint64_t _renderValue;
  uint64_t _presentValue;

  RenderImage _images[kImageCount];
  id<MTLTexture> _textures[kImageCount];
  VkImageUsageFlags _imageUsage;
  MTLPixelFormat _pixelFormat;
  int _imageWidth;
  int _imageHeight;
  unsigned _frameCount;

  id<MTLCommandQueue> _commandQueue;
  id<MTLCommandBuffer> _lastCommandBuffer;
  id<MTLTexture> _snapshotTexture;
  CIContext *_ciContext;
}

// MARK: - Setup

+ (nullable instancetype)createWithError:(NSError **)error {
  VulkanContext *context = [[super alloc] init];
  NSString *failure = [context setUp];
  if (failure) {
    [context destroy];
    if (error) *error = makeError(failure);
    return nil;
  }
  return context;
}

/// Returns `nil` on success, or the reason for the failure.
- (nullable NSString *)setUp {
  VkApplicationInfo app = {
    .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
    .pApplicationName = "IINA",
    .apiVersion = kApiVersion,
  };
  // MoltenVK is linked directly, without the Vulkan loader, so the instance
  // needs no surface or portability-enumeration extensions.
  VkInstanceCreateInfo instanceInfo = {
    .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    .pApplicationInfo = &app,
  };
  VkResult res = vkCreateInstance(&instanceInfo, NULL, &_instance);
  if (res != VK_SUCCESS)
    return [NSString stringWithFormat:@"vkCreateInstance failed (%d)", res];

  uint32_t count = 1;
  res = vkEnumeratePhysicalDevices(_instance, &count, &_physicalDevice);
  if ((res != VK_SUCCESS && res != VK_INCOMPLETE) || count == 0)
    return @"No Vulkan device was found";

  VkPhysicalDeviceProperties props;
  vkGetPhysicalDeviceProperties(_physicalDevice, &props);
  _deviceName = [NSString stringWithUTF8String:props.deviceName];
  if (props.apiVersion < kApiVersion)
    return [NSString stringWithFormat:@"%@ offers only Vulkan %u.%u", _deviceName,
            VK_API_VERSION_MAJOR(props.apiVersion), VK_API_VERSION_MINOR(props.apiVersion)];

  NSString *failure = [self chooseQueueFamily];
  if (!failure) failure = [self chooseExtensions];
  if (!failure) failure = [self chooseFeatures];
  if (!failure) failure = [self createDevice];
  if (!failure) failure = [self createSemaphores];
  if (failure) return failure;

  _commandQueue = [_metalDevice newCommandQueue];
  if (!_commandQueue) return @"Cannot create a Metal command queue";
  return nil;
}

- (nullable NSString *)chooseQueueFamily {
  uint32_t count = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(_physicalDevice, &count, NULL);
  VkQueueFamilyProperties families[count];
  vkGetPhysicalDeviceQueueFamilyProperties(_physicalDevice, &count, families);
  const VkQueueFlags needed = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
  for (uint32_t i = 0; i < count; i++) {
    if ((families[i].queueFlags & needed) == needed) {
      _queueFamily = i;
      return nil;
    }
  }
  return @"No Vulkan queue family has both graphics and compute";
}

- (nullable NSString *)chooseExtensions {
  uint32_t count = 0;
  vkEnumerateDeviceExtensionProperties(_physicalDevice, NULL, &count, NULL);
  // A heap array, because a block cannot capture a variable-length array.
  VkExtensionProperties *available = calloc(count ? count : 1, sizeof(*available));
  vkEnumerateDeviceExtensionProperties(_physicalDevice, NULL, &count, available);

  BOOL (^has)(const char *) = ^BOOL(const char *name) {
    for (uint32_t i = 0; i < count; i++)
      if (strcmp(available[i].extensionName, name) == 0) return YES;
    return NO;
  };

  // mpv's VideoToolbox decoder reads decoded frames through this extension
  // without a copy, and IINA itself exports its images and semaphores to Metal.
  if (!has(VK_EXT_METAL_OBJECTS_EXTENSION_NAME)) {
    free(available);
    return @"The Vulkan device lacks " VK_EXT_METAL_OBJECTS_EXTENSION_NAME;
  }
  _extensions[_extensionCount++] = VK_EXT_METAL_OBJECTS_EXTENSION_NAME;

  for (size_t i = 0; i < sizeof(kOptionalExtensions) / sizeof(kOptionalExtensions[0]); i++) {
    if (has(kOptionalExtensions[i]) && _extensionCount < kMaxExtensions)
      _extensions[_extensionCount++] = kOptionalExtensions[i];
  }
  free(available);
  return nil;
}

- (BOOL)hasExtension:(const char *)name {
  for (int i = 0; i < _extensionCount; i++)
    if (strcmp(_extensions[i], name) == 0) return YES;
  return NO;
}

/// Enables the features that libplacebo needs or recommends
/// (pl_vulkan_required_features and pl_vulkan_recommended_features), where
/// the device has them.
- (nullable NSString *)chooseFeatures {
  VkPhysicalDeviceVulkan13Features s13 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
  VkPhysicalDeviceVulkan12Features s12 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &s13};
  VkPhysicalDeviceVulkan11Features s11 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &s12};
  VkPhysicalDeviceFeatures2 s = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &s11};
  vkGetPhysicalDeviceFeatures2(_physicalDevice, &s);

  // libplacebo refuses a device without these two.
  if (!s12.hostQueryReset || !s12.timelineSemaphore)
    return @"The Vulkan device lacks hostQueryReset or timelineSemaphore";

  _features13 = (VkPhysicalDeviceVulkan13Features){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
  _features12 = (VkPhysicalDeviceVulkan12Features){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &_features13};
  _features11 = (VkPhysicalDeviceVulkan11Features){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &_features12};
  _features = (VkPhysicalDeviceFeatures2){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &_features11};

#define ENABLE(dst, src, name) dst.name = src.name
  ENABLE(_features.features, s.features, shaderImageGatherExtended);
  ENABLE(_features.features, s.features, shaderStorageImageReadWithoutFormat);
  ENABLE(_features.features, s.features, shaderStorageImageWriteWithoutFormat);
  ENABLE(_features.features, s.features, fragmentStoresAndAtomics);
  ENABLE(_features.features, s.features, vertexPipelineStoresAndAtomics);
  ENABLE(_features.features, s.features, shaderInt64);
  ENABLE(_features11, s11, samplerYcbcrConversion);
  ENABLE(_features11, s11, storagePushConstant16);
  ENABLE(_features12, s12, hostQueryReset);
  ENABLE(_features12, s12, timelineSemaphore);
  ENABLE(_features12, s12, bufferDeviceAddress);
  ENABLE(_features12, s12, storagePushConstant8);
  ENABLE(_features12, s12, shaderInt8);
  ENABLE(_features12, s12, shaderFloat16);
  ENABLE(_features12, s12, shaderSharedInt64Atomics);
  ENABLE(_features12, s12, storageBuffer8BitAccess);
  ENABLE(_features12, s12, uniformAndStorageBuffer8BitAccess);
  ENABLE(_features12, s12, vulkanMemoryModel);
  ENABLE(_features12, s12, vulkanMemoryModelDeviceScope);
  ENABLE(_features13, s13, computeFullSubgroups);
  ENABLE(_features13, s13, maintenance4);
  ENABLE(_features13, s13, shaderZeroInitializeWorkgroupMemory);
  ENABLE(_features13, s13, synchronization2);
#undef ENABLE
  return nil;
}

- (nullable NSString *)createDevice {
  float priority = 1.0f;
  VkDeviceQueueCreateInfo queueInfo = {
    .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    .queueFamilyIndex = _queueFamily,
    .queueCount = 1,
    .pQueuePriorities = &priority,
  };

  // A device with VK_KHR_portability_subset must state which of the
  // portability features it uses. Enable all that MoltenVK has. mpv does not
  // get this struct, because libplacebo does not know it.
  if ([self hasExtension:VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME]) {
    _portabilityFeatures = (VkPhysicalDevicePortabilitySubsetFeaturesKHR){
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PORTABILITY_SUBSET_FEATURES_KHR,
    };
    VkPhysicalDeviceFeatures2 query = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
      .pNext = &_portabilityFeatures,
    };
    vkGetPhysicalDeviceFeatures2(_physicalDevice, &query);
    _features13.pNext = &_portabilityFeatures;
  }

  VkDeviceCreateInfo info = {
    .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .pNext = &_features,
    .queueCreateInfoCount = 1,
    .pQueueCreateInfos = &queueInfo,
    .enabledExtensionCount = (uint32_t)_extensionCount,
    .ppEnabledExtensionNames = _extensions,
  };
  VkResult res = vkCreateDevice(_physicalDevice, &info, NULL, &_device);
  _features13.pNext = NULL;
  if (res != VK_SUCCESS)
    return [NSString stringWithFormat:@"vkCreateDevice failed (%d)", res];

  _exportMetalObjects = (PFN_vkExportMetalObjectsEXT)vkGetDeviceProcAddr(_device, "vkExportMetalObjectsEXT");
  if (!_exportMetalObjects) return @"vkExportMetalObjectsEXT is missing";

  VkExportMetalDeviceInfoEXT deviceExport = {.sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
  VkExportMetalObjectsInfoEXT exportInfo = {
    .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
    .pNext = &deviceExport,
  };
  _exportMetalObjects(_device, &exportInfo);
  _metalDevice = deviceExport.mtlDevice;
  if (!_metalDevice) return @"Cannot get the Metal device of the Vulkan device";
  return nil;
}

/// Creates a timeline semaphore that is also a Metal shared event.
- (nullable NSString *)createSemaphore:(VkSemaphore *)semaphore event:(id<MTLSharedEvent> __strong *)event {
  VkExportMetalObjectCreateInfoEXT exportCreate = {
    .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
    .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT,
  };
  VkSemaphoreTypeCreateInfo typeInfo = {
    .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
    .pNext = &exportCreate,
    .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
    .initialValue = 0,
  };
  VkSemaphoreCreateInfo info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &typeInfo};
  VkResult res = vkCreateSemaphore(_device, &info, NULL, semaphore);
  if (res != VK_SUCCESS)
    return [NSString stringWithFormat:@"vkCreateSemaphore failed (%d)", res];

  VkExportMetalSharedEventInfoEXT eventExport = {
    .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT,
    .semaphore = *semaphore,
  };
  VkExportMetalObjectsInfoEXT exportInfo = {
    .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
    .pNext = &eventExport,
  };
  _exportMetalObjects(_device, &exportInfo);
  *event = eventExport.mtlSharedEvent;
  if (!*event) return @"Cannot export a Vulkan timeline semaphore as a Metal shared event";
  return nil;
}

- (nullable NSString *)createSemaphores {
  NSString *failure = [self createSemaphore:&_renderSemaphore event:&_renderEvent];
  if (!failure) failure = [self createSemaphore:&_presentSemaphore event:&_presentEvent];
  return failure;
}

- (int)createRenderContext:(mpv_render_context **)context mpv:(mpv_handle *)mpv {
  mpv_vulkan_init_params init = {
    .instance = _instance,
    .get_instance_proc_addr = vkGetInstanceProcAddr,
    .api_version = kApiVersion,
    .physical_device = _physicalDevice,
    .device = _device,
    .extensions = _extensions,
    .num_extensions = _extensionCount,
    .features = &_features,
    .queue_graphics = {.index = _queueFamily, .count = 1},
    .queue_compute = {.index = _queueFamily, .count = 1},
    .queue_transfer = {.index = _queueFamily, .count = 1},
  };
  // Advanced control lets mpv run the screenshot command with the window flag
  // (see issue #4822), the same as for the OpenGL render API.
  int advanced = 1;
  mpv_render_param params[] = {
    {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_VULKAN},
    {MPV_RENDER_PARAM_VULKAN_INIT_PARAMS, &init},
    {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
    {0},
  };
  return mpv_render_context_create(context, mpv, params);
}

// MARK: - Render images

- (void)log:(NSString *)message {
  void (^handler)(NSString *) = self.logHandler;
  if (handler) handler(message);
}

- (void)destroyImages {
  [_lastCommandBuffer waitUntilCompleted];
  for (int i = 0; i < kImageCount; i++) {
    _textures[i] = nil;
    if (_images[i].image) vkDestroyImage(_device, _images[i].image, NULL);
    if (_images[i].memory) vkFreeMemory(_device, _images[i].memory, NULL);
    _images[i] = (RenderImage){0};
  }
  _snapshotTexture = nil;
  _imageWidth = _imageHeight = 0;
}

- (VkImageUsageFlags)chooseImageUsage {
  VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
  // Storage use lets mpv write the final pass with a compute shader. Add it
  // only if the format supports it.
  VkImageFormatProperties props;
  VkResult res = vkGetPhysicalDeviceImageFormatProperties(
      _physicalDevice, kImageFormat, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
      usage | VK_IMAGE_USAGE_STORAGE_BIT, 0, &props);
  if (res == VK_SUCCESS) usage |= VK_IMAGE_USAGE_STORAGE_BIT;
  return usage;
}

- (BOOL)createImage:(RenderImage *)image texture:(id<MTLTexture> __strong *)texture
              width:(int)width height:(int)height {
  VkExportMetalObjectCreateInfoEXT exportCreate = {
    .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
    .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT,
  };
  VkImageCreateInfo info = {
    .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    .pNext = &exportCreate,
    .imageType = VK_IMAGE_TYPE_2D,
    .format = kImageFormat,
    .extent = {(uint32_t)width, (uint32_t)height, 1},
    .mipLevels = 1,
    .arrayLayers = 1,
    .samples = VK_SAMPLE_COUNT_1_BIT,
    .tiling = VK_IMAGE_TILING_OPTIMAL,
    .usage = _imageUsage,
    .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
  };
  VkResult res = vkCreateImage(_device, &info, NULL, &image->image);
  if (res != VK_SUCCESS) {
    [self log:[NSString stringWithFormat:@"vkCreateImage failed (%d)", res]];
    return NO;
  }

  VkMemoryRequirements req;
  vkGetImageMemoryRequirements(_device, image->image, &req);
  VkPhysicalDeviceMemoryProperties mem;
  vkGetPhysicalDeviceMemoryProperties(_physicalDevice, &mem);
  uint32_t type = UINT32_MAX;
  for (uint32_t i = 0; i < mem.memoryTypeCount; i++) {
    if ((req.memoryTypeBits & (1u << i)) &&
        (mem.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
      type = i;
      break;
    }
  }
  if (type == UINT32_MAX) {
    [self log:@"No device-local memory type for the render image"];
    return NO;
  }
  VkMemoryAllocateInfo alloc = {
    .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    .allocationSize = req.size,
    .memoryTypeIndex = type,
  };
  res = vkAllocateMemory(_device, &alloc, NULL, &image->memory);
  if (res == VK_SUCCESS) res = vkBindImageMemory(_device, image->image, image->memory, 0);
  if (res != VK_SUCCESS) {
    [self log:[NSString stringWithFormat:@"Cannot allocate the render image (%d)", res]];
    return NO;
  }

  VkExportMetalTextureInfoEXT textureExport = {
    .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT,
    .image = image->image,
    .plane = VK_IMAGE_ASPECT_PLANE_0_BIT,
  };
  VkExportMetalObjectsInfoEXT exportInfo = {
    .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
    .pNext = &textureExport,
  };
  _exportMetalObjects(_device, &exportInfo);
  *texture = textureExport.mtlTexture;
  if (!*texture) {
    [self log:@"Cannot export the render image as a Metal texture"];
    return NO;
  }
  image->layout = VK_IMAGE_LAYOUT_UNDEFINED;
  // The present semaphore never goes down, so waiting for its current value
  // returns at once.
  image->releaseValue = _presentValue;
  return YES;
}

/// Makes sure that the render images have the given size. Recreating them
/// waits until the GPU has finished with the old images.
- (BOOL)ensureImagesWidth:(int)width height:(int)height {
  if (width == _imageWidth && height == _imageHeight && _images[0].image) return YES;
  [self destroyImages];
  if (!_imageUsage) _imageUsage = [self chooseImageUsage];
  for (int i = 0; i < kImageCount; i++) {
    if (![self createImage:&_images[i] texture:&_textures[i] width:width height:height]) {
      [self destroyImages];
      return NO;
    }
  }
  _pixelFormat = _textures[0].pixelFormat;
  _imageWidth = width;
  _imageHeight = height;
  return YES;
}

- (MTLPixelFormat)pixelFormat {
  // Before the first frame, report the format that MoltenVK uses for kImageFormat.
  return _pixelFormat != MTLPixelFormatInvalid ? _pixelFormat : MTLPixelFormatRGB10A2Unorm;
}

// MARK: - Render

- (VulkanFrameResult)renderFrame:(mpv_render_context *)context
                           layer:(nullable CAMetalLayer *)layer
                           width:(int)width
                          height:(int)height
                        snapshot:(nullable void (^)(CGImageRef _Nullable))snapshot {
  if (width <= 0 || height <= 0 || ![self ensureImagesWidth:width height:height]) {
    if (snapshot) snapshot(NULL);
    return VulkanFrameResultFailed;
  }
  int index = _frameCount++ % kImageCount;
  RenderImage *image = &_images[index];
  id<MTLTexture> texture = _textures[index];

  const uint64_t renderValue = _renderValue + 1;
  mpv_vulkan_image target = {
    .image = image->image,
    .format = kImageFormat,
    .usage = _imageUsage,
    .width = width,
    .height = height,
    .layout = image->layout,
    // Metal ignores Vulkan layouts, and GENERAL allows every use.
    .final_layout = VK_IMAGE_LAYOUT_GENERAL,
    .queue_family = VK_QUEUE_FAMILY_IGNORED,
    .wait_semaphore = _presentSemaphore,
    .wait_value = image->releaseValue,
    .signal_semaphore = _renderSemaphore,
    .signal_value = renderValue,
  };
  mpv_render_param params[] = {
    {MPV_RENDER_PARAM_VULKAN_IMAGE, &target},
    {0},
  };
  int err = mpv_render_context_render(context, params);
  if (err < 0) {
    // Most errors happen before mpv takes the image, and then mpv never
    // signals the semaphore. But a failed render still signals it. Check
    // briefly, so that Metal never waits for a signal that does not come.
    VkSemaphoreWaitInfo wait = {
      .sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
      .semaphoreCount = 1,
      .pSemaphores = &_renderSemaphore,
      .pValues = &renderValue,
    };
    if (vkWaitSemaphores(_device, &wait, 100 * NSEC_PER_MSEC) != VK_SUCCESS) {
      [self log:[NSString stringWithFormat:@"mpv_render_context_render failed: %s",
                 mpv_error_string(err)]];
      if (snapshot) snapshot(NULL);
      return VulkanFrameResultFailed;
    }
  }
  _renderValue = renderValue;
  image->layout = VK_IMAGE_LAYOUT_GENERAL;

  // nextDrawable blocks until the display has released a drawable, which
  // paces rendering to the display. It returns nil after one second, for
  // example when the layer is not on screen.
  if (layer && (layer.drawableSize.width != width || layer.drawableSize.height != height))
    layer.drawableSize = CGSizeMake(width, height);
  id<CAMetalDrawable> drawable = [layer nextDrawable];

  id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
  commandBuffer.label = @"IINA Vulkan present";
  [commandBuffer encodeWaitForEvent:_renderEvent value:renderValue];

  if (snapshot && (!_snapshotTexture || _snapshotTexture.width != (NSUInteger)width ||
                   _snapshotTexture.height != (NSUInteger)height)) {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture.pixelFormat
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    _snapshotTexture = [_metalDevice newTextureWithDescriptor:desc];
  }

  id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
  if (drawable) {
    id<MTLTexture> dst = drawable.texture;
    MTLSize size = MTLSizeMake(MIN((NSUInteger)width, dst.width), MIN((NSUInteger)height, dst.height), 1);
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:size toTexture:dst destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
  }
  // Copy the frame for a snapshot here, because mpv may render into `texture`
  // again as soon as this command buffer signals `present`.
  id<MTLTexture> snapshotTexture = snapshot ? _snapshotTexture : nil;
  if (snapshotTexture)
    [blit copyFromTexture:texture toTexture:snapshotTexture];
  [blit endEncoding];

  const uint64_t presentValue = ++_presentValue;
  [commandBuffer encodeSignalEvent:_presentEvent value:presentValue];
  image->releaseValue = presentValue;
  if (drawable) [commandBuffer presentDrawable:drawable];

  if (snapshot) {
    CGColorSpaceRef layerColorSpace = layer.colorspace;
    CGColorSpaceRef colorSpace = layerColorSpace ? CGColorSpaceRetain(layerColorSpace)
                                                 : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!_ciContext) _ciContext = [CIContext contextWithMTLDevice:_metalDevice];
    CIContext *ciContext = _ciContext;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
      CGImageRef cgImage = NULL;
      if (buffer.status == MTLCommandBufferStatusCompleted && snapshotTexture) {
        CIImage *ci = [CIImage imageWithMTLTexture:snapshotTexture
                                           options:@{kCIImageColorSpace: (__bridge id)colorSpace}];
        // Core Image puts the origin of a Metal texture at the bottom left,
        // but the frame has its first row at the top.
        ci = [ci imageByApplyingOrientation:kCGImagePropertyOrientationDownMirrored];
        CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        cgImage = [ciContext createCGImage:ci fromRect:ci.extent format:kCIFormatRGBA8 colorSpace:sRGB];
        CGColorSpaceRelease(sRGB);
      }
      snapshot(cgImage);
      CGImageRelease(cgImage);
      CGColorSpaceRelease(colorSpace);
    }];
  }
  [commandBuffer commit];
  _lastCommandBuffer = commandBuffer;
  return drawable ? VulkanFrameResultPresented : VulkanFrameResultNoDrawable;
}

// MARK: - Teardown

- (void)destroy {
  if (_device) {
    [self destroyImages];
    _lastCommandBuffer = nil;
    _renderEvent = nil;
    _presentEvent = nil;
    if (_renderSemaphore) vkDestroySemaphore(_device, _renderSemaphore, NULL);
    if (_presentSemaphore) vkDestroySemaphore(_device, _presentSemaphore, NULL);
    _renderSemaphore = _presentSemaphore = VK_NULL_HANDLE;
    vkDestroyDevice(_device, NULL);
    _device = VK_NULL_HANDLE;
  }
  if (_instance) {
    vkDestroyInstance(_instance, NULL);
    _instance = VK_NULL_HANDLE;
  }
  _commandQueue = nil;
  _ciContext = nil;
}

- (void)dealloc {
  [self destroy];
}

@end
