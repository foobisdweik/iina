// vtprobe: measures what VideoToolbox's ML video effects (VTFrameProcessor)
// can do on this Mac, so that the IINA upscaler can pick its settings.
//
//   vtprobe caps
//       Prints, for each test size, which effects and scale factors the OS
//       reports as supported.
//   vtprobe bench <clip> <llsr|sr|tnf> [factor] [frames]
//       Decodes <clip> and times one effect per frame.
//
// The effects:
//   llsr  low-latency super resolution (VTLowLatencySuperResolutionScaler),
//         a real-time upscaler that also reduces compression artifacts.
//   sr    super resolution (VTSuperResolutionScaler), a higher-quality
//         upscaler that uses the previous frame and its own previous output.
//   tnf   temporal noise filter (VTTemporalNoiseFilter), a denoiser that
//         compares the current frame with past and future frames.

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <time.h>

// The source sizes the upscaler must handle (short side 240..1440 px).
static const int kSizes[][2] = {
    {426, 240}, {640, 360}, {854, 480}, {1280, 720}, {1920, 1080}, {2560, 1440},
};
static const int kNumSizes = sizeof(kSizes) / sizeof(kSizes[0]);

// Warm-up frames are not timed: the first calls include one-time setup work.
static const int kWarmupFrames = 10;

static NSString *FourCC(OSType t) {
    char s[5] = {(char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t, 0};
    return [NSString stringWithUTF8String:s];
}

static NSString *FormatList(NSArray<NSNumber *> *formats) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSNumber *f in formats) [names addObject:FourCC(f.unsignedIntValue)];
    return [names componentsJoinedByString:@","];
}

static NSString *NumberList(NSArray<NSNumber *> *numbers) {
    if (numbers.count == 0) return @"none";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *n in numbers) [parts addObject:[NSString stringWithFormat:@"%g", n.doubleValue]];
    return [parts componentsJoinedByString:@","];
}

static uint64_t NowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// MARK: - caps

API_AVAILABLE(macos(26.0))
static void PrintCaps(void) {
    printf("macOS %s\n\n", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);

    // Low-latency super resolution.
    printf("== llsr (VTLowLatencySuperResolutionScaler)\n");
    printf("isSupported=%d\n", VTLowLatencySuperResolutionScalerConfiguration.isSupported);
    if (VTLowLatencySuperResolutionScalerConfiguration.isSupported) {
        CMVideoDimensions lo = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions;
        CMVideoDimensions hi = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions;
        printf("input dimensions: min %dx%d, max %dx%d\n", lo.width, lo.height, hi.width, hi.height);
        if (@available(macOS 27.0, *)) {
            NSArray<NSNumber *> *all = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors;
            printf("all scale factors: %s\n", NumberList(all).UTF8String);
            for (NSNumber *f in all) {
                printf("  factor %g: max dimension %ld, max pixel count %ld\n", f.doubleValue,
                       (long)[VTLowLatencySuperResolutionScalerConfiguration maximumDimensionForSpatialScaleFactor:f.floatValue],
                       (long)[VTLowLatencySuperResolutionScalerConfiguration maximumPixelCountForSpatialScaleFactor:f.floatValue]);
            }
        }
        for (int i = 0; i < kNumSizes; i++) {
            NSArray *factors = [VTLowLatencySuperResolutionScalerConfiguration
                supportedScaleFactorsForFrameWidth:kSizes[i][0] frameHeight:kSizes[i][1]];
            printf("  %4dx%-4d factors: %s\n", kSizes[i][0], kSizes[i][1], NumberList(factors).UTF8String);
        }
    }

    // Super resolution.
    printf("\n== sr (VTSuperResolutionScaler)\n");
    printf("isSupported=%d\n", VTSuperResolutionScalerConfiguration.isSupported);
    if (VTSuperResolutionScalerConfiguration.isSupported) {
        NSArray<NSNumber *> *factors = VTSuperResolutionScalerConfiguration.supportedScaleFactors;
        printf("scale factors: %s\n", NumberList(factors).UTF8String);
        for (int i = 0; i < kNumSizes; i++) {
            NSMutableArray *ok = [NSMutableArray array];
            NSString *status = @"-";
            for (NSNumber *f in factors) {
                VTSuperResolutionScalerConfiguration *c = [[VTSuperResolutionScalerConfiguration alloc]
                       initWithFrameWidth:kSizes[i][0]
                              frameHeight:kSizes[i][1]
                              scaleFactor:f.integerValue
                                inputType:VTSuperResolutionScalerConfigurationInputTypeVideo
                       usePrecomputedFlow:NO
                    qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal
                                 revision:VTSuperResolutionScalerConfiguration.defaultRevision];
                if (c) {
                    [ok addObject:f];
                    status = c.configurationModelStatus == VTSuperResolutionScalerConfigurationModelStatusReady ? @"ready"
                           : c.configurationModelStatus == VTSuperResolutionScalerConfigurationModelStatusDownloading ? @"downloading"
                           : @"download required";
                }
            }
            printf("  %4dx%-4d factors: %-8s model: %s\n", kSizes[i][0], kSizes[i][1],
                   NumberList(ok).UTF8String, status.UTF8String);
        }
    }

    // Temporal noise filter.
    printf("\n== tnf (VTTemporalNoiseFilter)\n");
    printf("isSupported=%d\n", VTTemporalNoiseFilterConfiguration.isSupported);
    if (VTTemporalNoiseFilterConfiguration.isSupported) {
        CMVideoDimensions lo = VTTemporalNoiseFilterConfiguration.minimumDimensions;
        CMVideoDimensions hi = VTTemporalNoiseFilterConfiguration.maximumDimensions;
        printf("input dimensions: min %dx%d, max %dx%d\n", lo.width, lo.height, hi.width, hi.height);
        NSArray<NSNumber *> *formats = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats;
        printf("source pixel formats: %s\n", FormatList(formats).UTF8String);
        OSType fmt = formats.count ? formats.firstObject.unsignedIntValue : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        for (int i = 0; i < kNumSizes; i++) {
            VTTemporalNoiseFilterConfiguration *c = [[VTTemporalNoiseFilterConfiguration alloc]
                initWithFrameWidth:kSizes[i][0] frameHeight:kSizes[i][1] sourcePixelFormat:fmt];
            if (c) {
                printf("  %4dx%-4d ok, previous frames %ld, next frames %ld\n", kSizes[i][0], kSizes[i][1],
                       (long)c.previousFrameCount, (long)c.nextFrameCount);
            } else {
                printf("  %4dx%-4d not supported\n", kSizes[i][0], kSizes[i][1]);
            }
        }
    }
}

// MARK: - bench helpers

// Reads decoded frames from a clip in the pixel format the effect needs.
@interface FrameSource : NSObject
@property(nonatomic) AVAssetReader *reader;
@property(nonatomic) AVAssetReaderTrackOutput *output;
@property(nonatomic) int width, height;
@property(nonatomic) double fps;
@end

@implementation FrameSource
- (instancetype)initWithPath:(NSString *)path pixelFormat:(OSType)format {
    if (!(self = [super init])) return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    NSError *error = nil;
    _reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!_reader) { fprintf(stderr, "cannot read %s: %s\n", path.UTF8String, error.description.UTF8String); return nil; }
    // The synchronous track API is deprecated but keeps this tool simple.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
#pragma clang diagnostic pop
    if (!track) { fprintf(stderr, "no video track in %s\n", path.UTF8String); return nil; }
    // Use the stored (coded) frame size. naturalSize applies the pixel aspect
    // ratio, so it can differ from the size of the decoded pixel buffers.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
#pragma clang diagnostic pop
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);
    _width = dims.width;
    _height = dims.height;
    _fps = track.nominalFrameRate;
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(format),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    _output.alwaysCopiesSampleData = NO;
    [_reader addOutput:_output];
    if (![_reader startReading]) {
        fprintf(stderr, "cannot start reading: %s\n", _reader.error.description.UTF8String);
        return nil;
    }
    return self;
}

// Returns the next frame, or nil at the end of the clip.
- (VTFrameProcessorFrame *)nextFrame API_AVAILABLE(macos(26.0)) {
    CMSampleBufferRef sample = [_output copyNextSampleBuffer];
    if (!sample) return nil;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    VTFrameProcessorFrame *frame = buffer
        ? [[VTFrameProcessorFrame alloc] initWithBuffer:buffer
                                  presentationTimeStamp:CMSampleBufferGetPresentationTimeStamp(sample)]
        : nil;
    CFRelease(sample);
    return frame;
}
@end

// Creates destination frames from the attributes the effect asks for.
static CVPixelBufferPoolRef MakePool(NSDictionary *attributes, int width, int height) {
    NSMutableDictionary *attrs = [attributes mutableCopy];
    if (!attrs[(id)kCVPixelBufferWidthKey]) attrs[(id)kCVPixelBufferWidthKey] = @(width);
    if (!attrs[(id)kCVPixelBufferHeightKey]) attrs[(id)kCVPixelBufferHeightKey] = @(height);
    CVPixelBufferPoolRef pool = NULL;
    CVReturn ret = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
    if (ret != kCVReturnSuccess) fprintf(stderr, "CVPixelBufferPoolCreate failed: %d\n", ret);
    return pool;
}

API_AVAILABLE(macos(26.0))
static VTFrameProcessorFrame *MakeDestination(CVPixelBufferPoolRef pool, CMTime pts) {
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &buffer) != kCVReturnSuccess) return nil;
    VTFrameProcessorFrame *frame = [[VTFrameProcessorFrame alloc] initWithBuffer:buffer presentationTimeStamp:pts];
    CVPixelBufferRelease(buffer);
    return frame;
}

// Picks the pixel format for decoding: 8-bit 4:2:0 video range if allowed.
static OSType PickFormat(NSArray<NSNumber *> *formats) {
    for (NSNumber *f in formats)
        if (f.unsignedIntValue == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return f.unsignedIntValue;
    return formats.count ? formats.firstObject.unsignedIntValue : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

// Waits until the super resolution model is on disk, downloading it if needed.
API_AVAILABLE(macos(26.0))
static BOOL EnsureModel(VTSuperResolutionScalerConfiguration *config) {
    if (config.configurationModelStatus == VTSuperResolutionScalerConfigurationModelStatusReady) return YES;
    printf("Super resolution model not ready, downloading...\n");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    [config downloadConfigurationModelWithCompletionHandler:^(NSError *error) {
        failure = error;
        dispatch_semaphore_signal(done);
    }];
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0)
        printf("  %.0f%% available\n", config.configurationModelPercentageAvailable);
    if (failure) fprintf(stderr, "model download failed: %s\n", failure.description.UTF8String);
    return failure == nil;
}

static void Report(const char *label, NSMutableArray<NSNumber *> *ms, double fps) {
    if (ms.count == 0) { printf("%s: no timed frames\n", label); return; }
    [ms sortUsingSelector:@selector(compare:)];
    double sum = 0;
    for (NSNumber *v in ms) sum += v.doubleValue;
    double avg = sum / ms.count;
    double p95 = ms[(NSUInteger)((ms.count - 1) * 0.95)].doubleValue;
    // The effect may use at most half of the frame interval, so that decoding
    // and IINA's renderer keep the other half.
    BOOL ok30 = p95 < 0.5 * 1000.0 / 30.0, ok60 = p95 < 0.5 * 1000.0 / 60.0;
    printf("%s: %lu frames, avg %.2f ms, p95 %.2f ms | 30 fps: %s, 60 fps: %s (clip %.3g fps)\n", label,
           (unsigned long)ms.count, avg, p95, ok30 ? "PASS" : "FAIL", ok60 ? "PASS" : "FAIL", fps);
}

// MARK: - bench

API_AVAILABLE(macos(26.0))
static int Bench(NSString *path, NSString *effect, double factor, int maxFrames) {
    // A probe read gives the clip size, which the configuration needs.
    FrameSource *probe = [[FrameSource alloc] initWithPath:path pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    if (!probe) return 1;
    int w = probe.width, h = probe.height;
    double fps = probe.fps;
    probe = nil;

    id<VTFrameProcessorConfiguration> config = nil;
    NSArray<NSNumber *> *formats = nil;
    int outW = w, outH = h;
    if ([effect isEqualToString:@"llsr"]) {
        VTLowLatencySuperResolutionScalerConfiguration *c =
            [[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:w frameHeight:h scaleFactor:(float)factor];
        config = c;
        formats = c.frameSupportedPixelFormats;
        outW = (int)lround(w * factor);
        outH = (int)lround(h * factor);
    } else if ([effect isEqualToString:@"sr"]) {
        VTSuperResolutionScalerConfiguration *c = [[VTSuperResolutionScalerConfiguration alloc]
               initWithFrameWidth:w
                      frameHeight:h
                      scaleFactor:(NSInteger)factor
                        inputType:VTSuperResolutionScalerConfigurationInputTypeVideo
               usePrecomputedFlow:NO
            qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal
                         revision:VTSuperResolutionScalerConfiguration.defaultRevision];
        if (!c) { fprintf(stderr, "sr: %dx%d at factor %g is not supported\n", w, h, factor); return 1; }
        if (!EnsureModel(c)) return 1;
        config = c;
        formats = c.frameSupportedPixelFormats;
        outW = w * (int)factor;
        outH = h * (int)factor;
    } else if ([effect isEqualToString:@"tnf"]) {
        OSType fmt = PickFormat(VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats);
        VTTemporalNoiseFilterConfiguration *c =
            [[VTTemporalNoiseFilterConfiguration alloc] initWithFrameWidth:w frameHeight:h sourcePixelFormat:fmt];
        if (!c) { fprintf(stderr, "tnf: %dx%d is not supported\n", w, h); return 1; }
        config = c;
        formats = c.frameSupportedPixelFormats;
    } else {
        fprintf(stderr, "unknown effect %s (use llsr, sr or tnf)\n", effect.UTF8String);
        return 1;
    }

    OSType format = PickFormat(formats);
    printf("%s %dx%d -> %dx%d, factor %g, pixel format %s (allowed: %s)\n", effect.UTF8String, w, h, outW, outH,
           factor, FourCC(format).UTF8String, FormatList(formats).UTF8String);

    VTFrameProcessor *processor = [[VTFrameProcessor alloc] init];
    NSError *error = nil;
    uint64_t t0 = NowNs();
    if (![processor startSessionWithConfiguration:config error:&error]) {
        fprintf(stderr, "startSession failed: %s\n", error.description.UTF8String);
        return 1;
    }
    printf("session start: %.1f ms (includes model loading)\n", (NowNs() - t0) / 1e6);

    CVPixelBufferPoolRef pool = MakePool(config.destinationPixelBufferAttributes, outW, outH);
    if (!pool) return 1;
    FrameSource *source = [[FrameSource alloc] initWithPath:path pixelFormat:format];
    if (!source) return 1;

    NSMutableArray<NSNumber *> *times = [NSMutableArray array];
    int processed = 0;

    if ([effect isEqualToString:@"tnf"]) {
        VTTemporalNoiseFilterConfiguration *c = (VTTemporalNoiseFilterConfiguration *)config;
        NSInteger prevCount = c.previousFrameCount, nextCount = c.nextFrameCount;
        // A sliding window: prevCount frames, the current frame, then nextCount frames.
        NSMutableArray<VTFrameProcessorFrame *> *window = [NSMutableArray array];
        BOOL first = YES;
        while (processed < maxFrames) {
            VTFrameProcessorFrame *f = [source nextFrame];
            if (!f) break;
            [window addObject:f];
            if ((NSInteger)window.count < prevCount + 1 + nextCount) continue;
            VTFrameProcessorFrame *current = window[prevCount];
            NSArray *prev = [window subarrayWithRange:NSMakeRange(0, prevCount)];
            NSArray *next = [window subarrayWithRange:NSMakeRange(prevCount + 1, nextCount)];
            VTFrameProcessorFrame *dst = MakeDestination(pool, current.presentationTimeStamp);
            VTTemporalNoiseFilterParameters *p = [[VTTemporalNoiseFilterParameters alloc] initWithSourceFrame:current
                                                                                                  nextFrames:next
                                                                                              previousFrames:prev
                                                                                            destinationFrame:dst
                                                                                              filterStrength:0.5
                                                                                            hasDiscontinuity:first];
            uint64_t s = NowNs();
            BOOL ok = [processor processWithParameters:p error:&error];
            uint64_t e = NowNs();
            if (!ok) { fprintf(stderr, "process failed: %s\n", error.description.UTF8String); break; }
            if (processed >= kWarmupFrames) [times addObject:@((e - s) / 1e6)];
            processed++;
            first = NO;
            [window removeObjectAtIndex:0];
        }
    } else {
        VTFrameProcessorFrame *prevSource = nil, *prevOutput = nil;
        while (processed < maxFrames) {
            VTFrameProcessorFrame *f = [source nextFrame];
            if (!f) break;
            VTFrameProcessorFrame *dst = MakeDestination(pool, f.presentationTimeStamp);
            id<VTFrameProcessorParameters> p;
            if ([effect isEqualToString:@"llsr"]) {
                p = [[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:f destinationFrame:dst];
            } else {
                p = [[VTSuperResolutionScalerParameters alloc] initWithSourceFrame:f
                                                                     previousFrame:prevSource
                                                               previousOutputFrame:prevOutput
                                                                       opticalFlow:nil
                                                                    submissionMode:VTSuperResolutionScalerParametersSubmissionModeSequential
                                                                  destinationFrame:dst];
            }
            uint64_t s = NowNs();
            BOOL ok = [processor processWithParameters:p error:&error];
            uint64_t e = NowNs();
            if (!ok) { fprintf(stderr, "process failed: %s\n", error.description.UTF8String); break; }
            if (processed >= kWarmupFrames) [times addObject:@((e - s) / 1e6)];
            processed++;
            prevSource = f;
            prevOutput = dst;
        }
    }

    [processor endSession];
    CVPixelBufferPoolRelease(pool);
    NSString *label = [NSString stringWithFormat:@"%@ %dx%d x%g", effect, w, h, factor];
    Report(label.UTF8String, times, fps);
    return times.count ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (@available(macOS 26.0, *)) {
            if (argc >= 2 && strcmp(argv[1], "caps") == 0) {
                PrintCaps();
                return 0;
            }
            if (argc >= 4 && strcmp(argv[1], "bench") == 0) {
                double factor = argc >= 5 ? atof(argv[4]) : 2.0;
                int frames = argc >= 6 ? atoi(argv[5]) : 300;
                return Bench([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]], factor, frames);
            }
            fprintf(stderr, "usage: vtprobe caps\n       vtprobe bench <clip> <llsr|sr|tnf> [factor] [frames]\n");
            return 2;
        }
        fprintf(stderr, "vtprobe needs macOS 26 or newer\n");
        return 1;
    }
}
