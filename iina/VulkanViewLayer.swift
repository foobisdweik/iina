//
//  VulkanViewLayer.swift
//  iina
//
//  Video layer that mpv renders into with Vulkan (MoltenVK).
//

import Cocoa

/// The interface that `VideoView` and the window controllers use for the video layer.
///
/// `ViewLayer` (OpenGL) and `VulkanViewLayer` (Vulkan) both implement it. Each layer type gets its frames from mpv
/// through a different mpv render API.
protocol VideoLayer: CALayer {
  /// `true` while the user resizes the window. Setting it forces a redraw.
  var inLiveResize: Bool { get set }
  var colorspace: CGColorSpace? { get set }
  var wantsExtendedDynamicRangeContent: Bool { get set }

  /// Draws a new frame on a background queue. With `force` set, the layer draws even if mpv has no new frame.
  func update(force: Bool)

  /// Captures the next rendered frame as an image.
  func captureSnapshot() async -> NSImage?

#if USE_ICC_PROFILE_AUTO // See VideoView.setICCProfile.
  func setRenderICCProfile(_ profile: NSColorSpace)
#endif
}

extension ViewLayer: VideoLayer {}

/// Metal layer for `VideoView` that mpv renders into through the Vulkan render API (`MPV_RENDER_API_TYPE_VULKAN`).
///
/// The Vulkan render API always uses mpv's `gpu-next` renderer on Vulkan. Unlike OpenGL on macOS, Vulkan has compute
/// shaders, so user shaders such as ArtCNN can run. `VulkanContext` owns the Vulkan device, and this layer decides when to
/// draw.
///
/// Drawing differs from `ViewLayer` in one main way. `CAOpenGLLayer` asks AppKit when to draw. A `CAMetalLayer` has no such
/// callback, so this layer draws on its own queue whenever mpv reports a new frame. `nextDrawable` blocks until the display has
/// released a drawable, and that paces drawing to the display.
final class VulkanViewLayer: CAMetalLayer, VideoLayer {

  private weak var videoView: VideoView!

  let vulkan: VulkanContext

  /// Serializes drawing, `destroyVulkan` and render parameter changes, so that only one thread uses the Vulkan images and
  /// the mpv render context at a time. This lock has the same job as the OpenGL context lock of `ViewLayer`: it must be
  /// locked before the `isUninited` lock of `VideoView`, to avoid deadlocks.
  let renderLock = NSRecursiveLock()

  private let renderQueue = DispatchQueue(label: "com.colliderli.iina.mpvvulkan", qos: .userInteractive)

  /// When `true` drawing will proceed even if mpv indicates nothing needs to be done.
  @Atomic private var forceDraw = false

  /// The size of the frame in pixels: the layer bounds times the scale factor of the screen.
  @Atomic private var pixelSize = CGSize.zero

  /// `false` while no part of the window is visible. Then `nextDrawable` would block for one second per frame, so the layer
  /// only lets mpv skip frames instead. This is the same case as the skip render in `ViewLayer.display` (issue #5025).
  @Atomic private var isWindowVisible = true

  private var occlusionObserver: NSObjectProtocol?

  @Atomic var inLiveResize: Bool = false {
    didSet { update(force: true) }
  }

  private let subsystem: Logger.Subsystem

  /// Returns a layer with a new Vulkan device, or `nil` if Vulkan is not usable. The caller then uses `ViewLayer`.
  init?(_ videoView: VideoView) {
    let vulkan: VulkanContext
    do {
      vulkan = try VulkanContext.create()
    } catch {
      Logger.log("Cannot use the Vulkan renderer: \(error.localizedDescription)", level: .warning)
      return nil
    }
    self.videoView = videoView
    self.vulkan = vulkan
    subsystem = Logger.makeSubsystem("vulkan\(videoView.player.playerNumber)", ["cpu"])
    super.init()
    let subsystem = subsystem
    vulkan.logHandler = { message in
      Logger.log(message, level: .error, subsystem: subsystem)
    }
    Logger.log("Created Vulkan device on \(vulkan.deviceName)", subsystem: subsystem)

    device = vulkan.metalDevice
    pixelFormat = vulkan.pixelFormat
    // IINA copies each frame into the drawable with a Metal blit, which needs a drawable that is more than a render target.
    framebufferOnly = false
    displaySyncEnabled = true
    isOpaque = true
    autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    backgroundColor = NSColor.black.cgColor
    // When resized but mpv hasn't rendered a new frame, the old content's aspect ratio should be preserved.
    contentsGravity = .resizeAspectFill

    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] notification in
        guard let self, let window = notification.object as? NSWindow, window === self.videoView?.window else { return }
        let visible = window.occlusionState.contains(.visible)
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        Logger.log("Window \(visible ? "visible" : "not visible"): \(visible ? "presenting" : "skipping") frames",
                   level: .debug, subsystem: subsystem)
        if visible { update(force: true) }
      }
  }

  /// Returns a shadow copy of the given layer. Core Animation calls this, for example when `contentsScale` changes. See
  /// `ViewLayer.init(layer:)`.
  override init(layer: Any) {
    let previousLayer = layer as! VulkanViewLayer
    videoView = previousLayer.videoView
    vulkan = previousLayer.vulkan
    subsystem = previousLayer.subsystem
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
  }

  override var bounds: CGRect {
    didSet { updatePixelSize() }
  }

  override var contentsScale: CGFloat {
    didSet { updatePixelSize() }
  }

  private func updatePixelSize() {
    let size = CGSize(width: (bounds.width * contentsScale).rounded(),
                      height: (bounds.height * contentsScale).rounded())
    guard size != pixelSize else { return }
    pixelSize = size
    // A shadow copy has no video view yet while Core Animation initializes it.
    guard videoView != nil else { return }
    update(force: true)
  }

  // MARK: - Draw

  func update(force: Bool) {
    renderQueue.async { [self] in
      if force { forceDraw = true }
      draw()
    }
  }

  private func draw() {
    guard let videoView, let mpv = videoView.player.mpv else { return }
    renderLock.lock()
    defer { renderLock.unlock() }
    videoView.$isUninited.withReadLock() { isUninited in
      guard !isUninited, let renderContext = mpv.mpvRenderContext else { return }
      let hasNewFrame = mpv.shouldRenderUpdateFrame()
      guard hasNewFrame || forceDraw else { return }
      forceDraw = false

      let size = pixelSize
      let hasSize = size.width >= 1 && size.height >= 1
      let handler = snapshotLock.withLock { () -> ((NSImage?) -> Void)? in
        let handler = pendingSnapshotHandler
        pendingSnapshotHandler = nil
        return handler
      }
      guard hasSize else {
        handler?(nil)
        if hasNewFrame { skipRender(renderContext) }
        return
      }
      let snapshot: ((CGImage?) -> Void)? = handler.map { handler in
        { image in handler(image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }) }
      }
      guard isWindowVisible else {
        // A capture (for Live Text) must not wait until the window is visible again, so render the frame without
        // presenting it. Otherwise let mpv drop the frame without drawing, so that playback continues.
        if let snapshot {
          _ = vulkan.renderFrame(renderContext, layer: nil, width: Int32(size.width), height: Int32(size.height),
                                 snapshot: snapshot)
        } else if hasNewFrame {
          skipRender(renderContext)
        }
        return
      }
      _ = vulkan.renderFrame(renderContext, layer: self, width: Int32(size.width), height: Int32(size.height),
                         snapshot: snapshot)
    }
  }

  private func skipRender(_ renderContext: OpaquePointer) {
    var skip: CInt = 1
    withUnsafeMutablePointer(to: &skip) { skip in
      var params: [mpv_render_param] = [
        mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: .init(skip)),
        mpv_render_param()
      ]
      mpv_render_context_render(renderContext, &params)
    }
  }

  // MARK: - Teardown

  /// Frees the Vulkan device. Call this after the mpv render context has been freed.
  func destroyVulkan() {
    renderLock.lock()
    defer { renderLock.unlock() }
    vulkan.destroy()
  }

  // MARK: - Snapshot

  private let snapshotLock = Lock()
  private var pendingSnapshotHandler: ((NSImage?) -> Void)?

  /// Capture the next rendered frame as an `NSImage`. Forces a redraw so this works while paused.
  func captureSnapshot() async -> NSImage? {
    await withCheckedContinuation { continuation in
      // Drop any previous in-flight request — only the latest caller wins.
      let previous = snapshotLock.withLock { () -> ((NSImage?) -> Void)? in
        let previous = pendingSnapshotHandler
        pendingSnapshotHandler = { image in
          continuation.resume(returning: image)
        }
        return previous
      }
      previous?(nil)
      update(force: true)
    }
  }

  // MARK: - ICC Profile

#if USE_ICC_PROFILE_AUTO // See VideoView.setICCProfile.
  /// Set an ICC profile for use with the mpv `icc-profile-auto` option. See `ViewLayer.setRenderICCProfile`.
  func setRenderICCProfile(_ profile: NSColorSpace) {
    renderLock.lock()
    defer { renderLock.unlock() }
    videoView.$isUninited.withReadLock() { isUninited in
      guard !isUninited, let renderContext = videoView.player.mpv.mpvRenderContext else { return }
      guard var iccData = profile.iccProfileData else {
        let name = profile.localizedName ?? "unnamed"
        Logger.log("Color space \(name) does not contain ICC profile data", level: .warning)
        return
      }
      iccData.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
        guard let baseAddress = ptr.baseAddress, ptr.count > 0 else { return }
        var icc = mpv_byte_array(data: baseAddress.assumingMemoryBound(to: UInt8.self), size: ptr.count)
        withUnsafeMutableBytes(of: &icc) { ptr in
          mpv_render_context_set_parameter(renderContext,
                                           mpv_render_param(type: MPV_RENDER_PARAM_ICC_PROFILE, data: ptr.baseAddress))
        }
      }
    }
  }
#endif
}
