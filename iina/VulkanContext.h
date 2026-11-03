//
//  VulkanContext.h
//  iina
//
//  The Vulkan device that mpv renders into when IINA uses the Vulkan render
//  API (MPV_RENDER_API_TYPE_VULKAN from mpv/render_vk.h).
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mpv/client.h>
#import <mpv/render.h>

NS_ASSUME_NONNULL_BEGIN

/// The value of MPV_RENDER_API_TYPE_VULKAN, for Swift code that does not import mpv/render_vk.h.
extern NSString * const VulkanRenderAPIType;

typedef NS_ENUM(NSInteger, VulkanFrameResult) {
  /// mpv rendered the frame, and it was presented on the layer.
  VulkanFrameResultPresented,
  /// mpv rendered the frame, but the layer gave no drawable (for example, the
  /// layer is not on screen), so nothing was presented.
  VulkanFrameResultNoDrawable,
  /// mpv did not render the frame. The reason is passed to the log handler.
  VulkanFrameResultFailed,
};

/// Owns a Vulkan instance and device on MoltenVK (Vulkan on Metal), lets mpv
/// render each frame into a Vulkan image, and presents that image on a
/// `CAMetalLayer` with Metal.
///
/// IINA presents with Metal instead of a Vulkan swapchain (`VK_KHR_swapchain`),
/// because MoltenVK's swapchain sets the color space of the layer itself. IINA
/// must set that color space for HDR (for example `itur_2100_PQ`), so IINA owns
/// the layer and MoltenVK never touches it.
///
/// How one frame flows:
/// 1. mpv waits until Metal has finished reading the image from its last use
///    (the `present` timeline semaphore).
/// 2. mpv renders into the image and signals the `render` timeline semaphore.
/// 3. A Metal command buffer waits for that signal, copies the image into the
///    layer's drawable, signals `present`, and presents the drawable.
///
/// Two images alternate, so that mpv can render the next frame while Metal still
/// copies the previous one. Both semaphores are also Metal shared events
/// (`VK_EXT_metal_objects`), so Vulkan and Metal wait on each other on the GPU,
/// without blocking a CPU thread.
///
/// Threading: call `renderFrame` and `destroy` under one lock, because they
/// share the images. `createRenderContext` may run on any thread.
@interface VulkanContext : NSObject

/// The Metal device behind the Vulkan device. The layer must use this device.
@property (nonatomic, readonly) id<MTLDevice> metalDevice;

/// The pixel format of the render images. The layer must use this format,
/// because a Metal copy needs equal formats. It has 10 bits per color, which
/// HDR10 (PQ) output needs.
@property (nonatomic, readonly) MTLPixelFormat pixelFormat;

/// The name of the GPU, for the log.
@property (nonatomic, readonly, copy) NSString *deviceName;

/// Receives messages about failures, for IINA's log.
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *message);

/// Creates the Vulkan instance and device. Returns `nil` and sets `error` if
/// MoltenVK lacks something that IINA needs. Swift sees this as `create() throws`.
///
/// This is a factory method with its own name, because an initializer named `initWithError:` reaches Swift as `init()`,
/// the same name as `NSObject.init()`, and Swift then calls the wrong one.
+ (nullable instancetype)createWithError:(NSError * _Nullable * _Nullable)error;
- (instancetype)init NS_UNAVAILABLE;

/// Creates an mpv render context that renders with this device. Returns an mpv
/// error code: 0 or more means success.
- (int)createRenderContext:(mpv_render_context * _Nullable * _Nonnull)context
                       mpv:(mpv_handle *)mpv;

/// Renders the current mpv frame and presents it on `layer`.
///
/// This may block until the layer has a free drawable, which paces rendering
/// to the display.
/// - Parameters:
///   - width: The width of the frame in pixels.
///   - height: The height of the frame in pixels.
///   - snapshot: If not `nil`, receives a copy of this frame as an image, or
///     `NULL` if the frame failed. It is called on a Metal thread.
- (VulkanFrameResult)renderFrame:(mpv_render_context *)context
                           layer:(nullable CAMetalLayer *)layer
                           width:(int)width
                          height:(int)height
                        snapshot:(nullable void (^)(CGImageRef _Nullable image))snapshot;

/// Waits for the GPU and frees all Vulkan objects. Call this only after
/// `mpv_render_context_free`, because mpv uses the device until then.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
