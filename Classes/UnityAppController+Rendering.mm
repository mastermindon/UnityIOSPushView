#include "UnityAppController+Rendering.h"
#include "UnityAppController+ViewHandling.h"

#include "Unity/InternalProfiler.h"
#include "Unity/UnityMetalSupport.h"
#include "Unity/DisplayManager.h"

#include "UI/UnityView.h"

#include <dlfcn.h>

// On some devices presenting render buffer may sporadically take long time to complete even with very simple scenes.
// In these cases display link still fires at steady frame rate but input processing becomes stuttering.
// As a workaround this switch disables display link during rendering a frame.
// If you are running a GPU bound scene and experience frame drop you may want to disable this switch.
#define ENABLE_DISPLAY_LINK_PAUSING 1
#define ENABLE_RUNLOOP_ACCEPT_INPUT 1

// _glesContextCreated was renamed to _renderingInited
extern bool _renderingInited;
extern bool _unityAppReady;
extern bool _skipPresent;
extern bool _didResignActive;

static int _renderingAPI = 0;
static int SelectRenderingAPIImpl();

static bool _enableRunLoopAcceptInput = false;

@implementation UnityAppController (Rendering)

- (void)createDisplayLink
{
    _displayLink = [CADisplayLink displayLinkWithTarget: self selector: @selector(repaintDisplayLink)];
    [self callbackFramerateChange: -1];
    [_displayLink addToRunLoop: [NSRunLoop currentRunLoop] forMode: NSRunLoopCommonModes];
}

- (void)destroyDisplayLink
{
    [_displayLink invalidate];
    _displayLink = nil;
}

- (void)processTouchEvents
{
    // On multicore devices running at 60 FPS some touch event delivery isn't properly interleaved with graphical frames.
    // Running additional run loop here improves event handling in those cases.
    // Passing here an NSDate from the past invokes run loop only once.
#if ENABLE_RUNLOOP_ACCEPT_INPUT
    // We get "NSInternalInconsistencyException: unexpected start state" exception if there are events queued and app is
    // going to background at the same time. This happens when we render additional frame after receiving
    // applicationWillResignActive. So check if we are supposed to ignore input.
    bool ignoreInput = [[UIApplication sharedApplication] isIgnoringInteractionEvents];
    if (!ignoreInput && _enableRunLoopAcceptInput)
    {
        static NSDate* past = [NSDate dateWithTimeIntervalSince1970: 0]; // the oldest date we can get
        [[NSRunLoop currentRunLoop] acceptInputForMode: NSDefaultRunLoopMode beforeDate: past];
    }
#endif
}

- (void)repaintDisplayLink
{
#if ENABLE_DISPLAY_LINK_PAUSING
    _displayLink.paused = YES;
#endif
    if (!_didResignActive)
    {
        UnityDisplayLinkCallback(_displayLink.timestamp);
        [self repaint];
        [self processTouchEvents];
    }

#if ENABLE_DISPLAY_LINK_PAUSING
    _displayLink.paused = NO;
#endif
}

- (void)repaint
{
#if UNITY_SUPPORT_ROTATION
    [self checkOrientationRequest];
#endif
    for(NSString* key in viewDic)
    {
        UnityView* view = viewDic[key];
        [view recreateRenderingSurfaceIfNeeded];
        [view processKeyboard];
    }
    UnityDeliverUIEvents();

    if (!UnityIsPaused())
        UnityRepaint();
}

- (void)callbackGfxInited
{
    InitRendering();
    _renderingInited = true;

    [self shouldAttachRenderDelegate];
    for(NSString* key in viewDic)
    {
        UnityView* view = viewDic[key];
        [view recreateRenderingSurface];
    }

    [_renderDelegate mainDisplayInited: _mainDisplay.surface];

    _mainDisplay.surface->allowScreenshot = 1;
}

- (void)callbackPresent:(const UnityFrameStats*)frameStats
{
    if (_skipPresent || _didResignActive)
        return;

    // metal needs special processing, because in case of airplay we need extra command buffers to present non-main screen drawables
    if (UnitySelectedRenderingAPI() == apiMetal)
    {
    #if UNITY_CAN_USE_METAL
        [[DisplayManager Instance].mainDisplay present];
        [[DisplayManager Instance] enumerateNonMainDisplaysWithBlock:^(DisplayConnection* conn) {
            PreparePresentNonMainScreenMTL((UnityDisplaySurfaceMTL*)conn.surface);
        }];
    #endif
    }
    else
    {
        [[DisplayManager Instance] present];
    }

    Profiler_FramePresent(frameStats);
}

- (void)callbackFramerateChange:(int)targetFPS
{
    int maxFPS = (int)[UIScreen mainScreen].maximumFramesPerSecond;
    if (targetFPS <= 0)
        targetFPS = UnityGetTargetFPS();
    if (targetFPS > maxFPS)
    {
        targetFPS = maxFPS;
        UnitySetTargetFPS(targetFPS);
        return;
    }

    _enableRunLoopAcceptInput = (targetFPS == maxFPS && UnityDeviceCPUCount() > 1);

#if UNITY_HAS_IOSSDK_15_0 && UNITY_HAS_TVOSSDK_15_0
    if (@available(iOS 15.0, tvOS 15.0, *))
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(targetFPS, targetFPS, targetFPS);
    else
#endif
    _displayLink.preferredFramesPerSecond = targetFPS;
}

- (void)selectRenderingAPI
{
    NSAssert(_renderingAPI == 0, @"[UnityAppController selectRenderingApi] called twice");
    _renderingAPI = SelectRenderingAPIImpl();
}

- (UnityRenderingAPI)renderingAPI
{
    NSAssert(_renderingAPI != 0, @"[UnityAppController renderingAPI] called before [UnityAppController selectRenderingApi]");
    return (UnityRenderingAPI)_renderingAPI;
}

@end


extern "C" void UnityGfxInitedCallback()
{
    [GetAppController() callbackGfxInited];
}

extern "C" void UnityPresentContextCallback(struct UnityFrameStats const* unityFrameStats)
{
    [GetAppController() callbackPresent: unityFrameStats];
}

extern "C" void UnityFramerateChangeCallback(int targetFPS)
{
    [GetAppController() callbackFramerateChange: targetFPS];
}

static NSBundle*        _MetalBundle    = nil;
static id<MTLDevice>    _MetalDevice    = nil;

static bool IsMetalSupported(int /*api*/)
{
    _MetalBundle = [NSBundle bundleWithPath: @"/System/Library/Frameworks/Metal.framework"];
    if (_MetalBundle)
    {
        [_MetalBundle load];
        _MetalDevice = ((MTLCreateSystemDefaultDeviceFunc)::dlsym(dlopen(0, RTLD_LOCAL | RTLD_LAZY), "MTLCreateSystemDefaultDevice"))();
        if (_MetalDevice)
            return true;
    }

    [_MetalBundle unload];
    return false;
}

static int SelectRenderingAPIImpl()
{
    const int api = UnityGetRenderingAPI();
    if (api == apiMetal && IsMetalSupported(0))
        return api;

#if TARGET_IPHONE_SIMULATOR || TARGET_TVOS_SIMULATOR
    printf_console("On Simulator, Metal is supported only from iOS 13, and it requires at least macOS 10.15 and Xcode 11. Setting no graphics device.\n");
    return apiNoGraphics;
#else
    assert(false);
    return 0;
#endif
}

extern "C" NSBundle*            UnityGetMetalBundle()
{
    return _MetalBundle;
}

extern "C" MTLDeviceRef         UnityGetMetalDevice()       { return _MetalDevice; }
extern "C" MTLCommandQueueRef   UnityGetMetalCommandQueue() { return ((UnityDisplaySurfaceMTL*)GetMainDisplaySurface())->commandQueue; }
extern "C" MTLCommandQueueRef   UnityGetMetalDrawableCommandQueue() { return ((UnityDisplaySurfaceMTL*)GetMainDisplaySurface())->drawableCommandQueue; }

extern "C" int                  UnitySelectedRenderingAPI() { return _renderingAPI; }

extern "C" UnityRenderBufferHandle  UnityBackbufferColor()      { return GetMainDisplaySurface()->unityColorBuffer; }
extern "C" UnityRenderBufferHandle  UnityBackbufferDepth()      { return GetMainDisplaySurface()->unityDepthBuffer; }

extern "C" void                 DisplayManagerEndFrameRendering() { [[DisplayManager Instance] endFrameRendering]; }

extern "C" void                 UnityPrepareScreenshot()    { UnitySetRenderTarget(GetMainDisplaySurface()->unityColorBuffer, GetMainDisplaySurface()->unityDepthBuffer); }

extern "C" void UnityRepaint()
{
    @autoreleasepool
    {
        Profiler_FrameStart();
        UnityPlayerLoop();
        Profiler_FrameEnd();
    }
}
