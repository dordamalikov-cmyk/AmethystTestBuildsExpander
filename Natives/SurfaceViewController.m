#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdarg.h>

#import "authenticator/BaseAuthenticator.h"
#import "customcontrols/ControlButton.h"
#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlSubButton.h"
#import "customcontrols/CustomControlsUtils.h"

#import "input/ControllerInput.h"
#import "input/GyroInput.h"
#import "input/KeyboardInput.h"

#import "AMPassthroughView.h"

#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "TrackedTextField.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"

#include "glfw_keycodes.h"
#include "utils.h"

#include <dlfcn.h>

int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT        6

static int currentHotbarSlot = -1;
static GameSurfaceView* pojavWindow;
static void *g_lastSDLWindowPtr = NULL;   // diag: detect SDL window recreation between polls
static BOOL g_sdlPostActivationDumped = NO; // one-shot hierarchy dump after first successful SDL-mode activation
static BOOL g_sdlHierarchyDumped = NO;      // one-shot hierarchy dump in sdlSurfaceReady: (was firing per SDL window event)

// extern in SurfaceViewController.h; read by input_bridge_v3.m to route keys to SDL.
BOOL g_sdlInputActive = NO;

// ---- SDL3 ABI mirror for the native surface-ready event watch (SDL_events.h, 3.4.0) ----
// org.lwjgl.sdl.SDL is a stub, so window events are captured natively from the bundled
// libSDL3.dylib that the game loads. SDL_Event.type is the first 32-bit field of the struct.
typedef uint32_t SDL3_EventType;
typedef int  (*SDL3_EventFilter)(void *userdata, void *event);      // SDL_bool (SDLCALL *)(void*, SDL_Event*)
typedef bool (*SDL3_AddEventWatchFn)(SDL3_EventFilter filter, void *userdata);
typedef bool (*SDL3_DelEventWatchFn)(SDL3_EventFilter filter, void *userdata);

enum {
    SDL3_EVENT_WINDOW_SHOWN              = 0x202,
    SDL3_EVENT_WINDOW_HIDDEN             = 0x203,
    SDL3_EVENT_WINDOW_EXPOSED            = 0x204,
    SDL3_EVENT_WINDOW_MOVED              = 0x205,
    SDL3_EVENT_WINDOW_RESIZED            = 0x206,
    SDL3_EVENT_WINDOW_PIXEL_SIZE_CHANGED = 0x207,
    SDL3_EVENT_WINDOW_MINIMIZED          = 0x208,
    SDL3_EVENT_WINDOW_MAXIMIZED          = 0x209,
};

static SDL3_EventFilter     g_sdlFilter = NULL;
static SDL3_DelEventWatchFn g_sdlDelWatch = NULL;
static __weak SurfaceViewController *g_sdlSurfaceVC = NULL;   // weak — auto-nils after dealloc
static dispatch_source_t    g_sdlSafetyTimer = NULL;
static BOOL                 g_sdlSurfaceSynced = NO;

// Diagnostic: mirror a message to the unified log (NSLog) AND to the app's stderr,
// which init_redirectStdio dup2's into latestlog.txt + the in-app log viewer. The
// view-hierarchy / SDL-window dumps funnel through here so they land in the same
// on-device log the launcher shows — no separate Console.app needed.
static void SDLDiagLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@", msg);
    fprintf(stderr, "%s\n", msg.UTF8String);
}

@interface SurfaceViewController ()<UITextFieldDelegate, UIGestureRecognizerDelegate> {
}

@property(nonatomic) NSDictionary* metadata;

@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) NSMutableArray* swipeableButtons;
@property(nonatomic) ControlButton* swipingButton;
@property(nonatomic) UITouch *primaryTouch, *hotbarTouch;

@property(nonatomic) UILongPressGestureRecognizer* longPressGesture, *longPressTwoGesture;
@property(nonatomic) UITapGestureRecognizer *tapGesture, *doubleTapGesture;

@property(nonatomic) id mouseConnectCallback, mouseDisconnectCallback;
@property(nonatomic) id controllerConnectCallback, controllerDisconnectCallback;

@property(nonatomic) CGFloat screenScale;
@property(nonatomic) CGFloat mouseSpeed;
@property(nonatomic) CGRect clickRange;
@property(nonatomic) BOOL isMacCatalystApp, shouldHideControlsFromRecording,
    shouldTriggerClick, shouldTriggerHaptic, slideableHotbar, toggleHidden;

@property(nonatomic) BOOL enableMouseGestures, enableHotbarGestures;

@property(nonatomic) UIImpactFeedbackGenerator *lightHaptic;
@property(nonatomic) UIImpactFeedbackGenerator *mediumHaptic;

- (void)installSDLSurfaceWatch;
- (void)uninstallSDLSurfaceWatch;
- (void)sdlSurfaceReady:(BOOL)fromEvent;

@end

// Called on the game's SDL event-pumping thread; hop to main before touching UIKit.
static int SurfaceSDLSurfaceEventFilter(void *userdata, void *event) {
    SurfaceViewController *vc = g_sdlSurfaceVC;   // weak — nil once the VC is gone
    if (!vc) return 0;
    switch (((SDL3_EventType *)event)[0]) {
        case SDL3_EVENT_WINDOW_SHOWN:
        case SDL3_EVENT_WINDOW_EXPOSED:
        case SDL3_EVENT_WINDOW_RESIZED:
        case SDL3_EVENT_WINDOW_PIXEL_SIZE_CHANGED: {
            dispatch_async(dispatch_get_main_queue(), ^{
                [vc sdlSurfaceReady:YES];
            });
            break;
        }
        default: {
            // [Amethyst diag] temporary: log unhandled *window-class* events (0x200..0x22F)
            // so the log shows whether WINDOW_SHOWN ever arrives at startup (forceshow
            // patch) or the first real window event is a RESIZED from rotation. Full
            // logging of every type would flood the log with input/render events.
            uint32_t t = ((SDL3_EventType *)event)[0];
            if (t >= 0x200 && t <= 0x22F) {
                NSLog(@"[SDL Watch] unhandled SDL window event type: 0x%x", t);
            }
            break;
        }
    }
    return 0; // SDL_FALSE — keep the event in the queue
}

@implementation SurfaceViewController

- (instancetype)initWithMetadata:(NSDictionary *)metadata {
    self = [super init];
    self.metadata = metadata;
    return self;
}

- (void)dealloc {
    // Remove the SDL event watch so the filter never fires into a deallocated
    // SurfaceViewController (e.g. on relaunch).
    [self uninstallSDLSurfaceWatch];
}

- (void)loadView
{
    // Passthrough view: empty zones of the launcher fall through to the SDL window below,
    // so the game still receives touches where no control button sits.
    self.view = [[AMPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    isControlModifiable = NO;
    self.isMacCatalystApp = NSProcessInfo.processInfo.isMacCatalystApp;
    // Load MetalHUD library
    dlopen("/usr/lib/libMTLHud.dylib", 0);

    self.lightHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleLight)];
    self.mediumHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleMedium)];

    //setPrefBool(@"internal.internal_launch_on_boot", NO);

    UIApplication.sharedApplication.idleTimerDisabled = YES;
    BOOL isTVOS = realUIIdiom == UIUserInterfaceIdiomTV;
    if (!isTVOS) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }

    // Perform Gamepad joystick ticking, while also controlling frame rate?
    id tickInput = ^{
        [GyroInput tick];
        [ControllerInput tick];
    };
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:tickInput selector:@selector(invoke)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        if(getPrefBool(@"video.max_framerate")) {
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        } else {
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        }
    }
    [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];

    CGFloat screenScale = UIScreen.mainScreen.scale;

    [self updateSavedResolution];

    self.rootView = [[AMPassthroughView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width + 30.0, self.view.frame.size.height)];
    [self.view addSubview:self.rootView];
    // [Passthrough] Right-edge strip (где UIScreenEdgePanGestureRecognizer распознаёт
    // начало свайпа) остаётся внутри окна лаунчера — edgeGesture должен увидеть тач.
    ((AMPassthroughView *)self.rootView).rightEdgeExclusion = 24.0;

    self.ctrlView = [[ControlLayout alloc] initWithFrame:getSafeArea(self.view.frame)];

    [self performSelector:@selector(initCategory_Navigation)];
    
    self.surfaceView = [[GameSurfaceView alloc] initWithFrame:self.view.frame];
    self.surfaceView.layer.contentsScale = screenScale * resolutionScale;
    self.surfaceView.layer.magnificationFilter = self.surfaceView.layer.minificationFilter = kCAFilterNearest;
    self.surfaceView.multipleTouchEnabled = YES;
    pojavWindow = self.surfaceView;

    self.touchView = [[UIView alloc] initWithFrame:self.view.frame];
    self.touchView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:1];
    self.touchView.multipleTouchEnabled = YES;
    [self.touchView addSubview:self.surfaceView];

    [self.rootView addSubview:self.touchView];
    [self.rootView addSubview:self.ctrlView];

    [self performSelector:@selector(setupCategory_Navigation)];

    
    UIHoverGestureRecognizer *hoverGesture = [[NSClassFromString(@"UIHoverGestureRecognizer") alloc] initWithTarget:self action:@selector(surfaceOnHover:)];
    [self.touchView addGestureRecognizer:hoverGesture];

    self.tapGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnClick:)];
    self.tapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.tapGesture.delegate = self;
    self.tapGesture.numberOfTapsRequired = 1;
    self.tapGesture.numberOfTouchesRequired = 1;
    self.tapGesture.cancelsTouchesInView = NO;
    [self.touchView addGestureRecognizer:self.tapGesture];

    self.doubleTapGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnDoubleClick:)];
    self.doubleTapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.doubleTapGesture.delegate = self;
    self.doubleTapGesture.numberOfTapsRequired = 2;
    self.doubleTapGesture.numberOfTouchesRequired = 1;
    self.doubleTapGesture.cancelsTouchesInView = NO;
    [self.touchView addGestureRecognizer:self.doubleTapGesture];

    self.longPressGesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnLongpress:)];
    self.longPressGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressGesture.cancelsTouchesInView = NO;
    self.longPressGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressGesture];
    
    self.longPressTwoGesture = [[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(keyboardGesture:)];
    self.longPressTwoGesture.numberOfTouchesRequired = 2;
    self.longPressTwoGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressTwoGesture.cancelsTouchesInView = NO;
    self.longPressTwoGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressTwoGesture];

    self.scrollPanGesture = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnTouchesScroll:)];
    self.scrollPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.scrollPanGesture.delegate = self;
    self.scrollPanGesture.minimumNumberOfTouches = 2;
    self.scrollPanGesture.maximumNumberOfTouches = 2;
    [self.touchView addGestureRecognizer:self.scrollPanGesture];

    // Virtual mouse
    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:virtualMouseFrame];
    self.mousePointerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin |UIViewAutoresizingFlexibleBottomMargin;
    self.mousePointerView.hidden = !virtualMouseEnabled;
    self.mousePointerView.image = [UIImage imageNamed:@"MousePointer"];
    self.mousePointerView.userInteractionEnabled = NO;
    [self.touchView addSubview:self.mousePointerView];

    self.inputTextField = [[TrackedTextField alloc] initWithFrame:CGRectMake(0, -32.0, self.view.frame.size.width, 30.0)];
    self.inputTextField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.inputTextField.delegate = self;
    self.inputTextField.font = [UIFont fontWithName:@"Menlo-Regular" size:20];
    self.inputTextField.clearsOnBeginEditing = YES;
    self.inputTextField.textAlignment = NSTextAlignmentCenter;
    self.inputTextField.sendChar = ^(jchar keychar){
        CallbackBridge_nativeSendChar(keychar);
    };
    self.inputTextField.sendCharMods = ^(jchar keychar, int mods){
        CallbackBridge_nativeSendCharMods(keychar, mods);
    };
    self.inputTextField.sendKey = ^(int key, int scancode, int action, int mods) {
        CallbackBridge_nativeSendKey(key, scancode, action, mods);
    };

    self.swipeableButtons = [[NSMutableArray alloc] init];

    [KeyboardInput initKeycodeTable];
    self.mouseConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"Input: Mouse connected!");
        GCMouse* mouse = note.object;
        [self registerMouseCallbacks:mouse];
        self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
        [self setNeedsUpdateOfPrefersPointerLocked];
    }];
    self.mouseDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"Input: Mouse disconnected!");
        GCMouse* mouse = note.object;
        mouse.mouseInput.mouseMovedHandler = nil;
        mouse.mouseInput.leftButton.pressedChangedHandler = nil;
        mouse.mouseInput.middleButton.pressedChangedHandler = nil;
        mouse.mouseInput.rightButton.pressedChangedHandler = nil;
        [mouse.mouseInput.auxiliaryButtons makeObjectsPerformSelector:@selector(setPressedChangedHandler:) withObject:nil];
        [self setNeedsUpdateOfPrefersPointerLocked];
        if (getPrefBool(@"controll.hardware_hide")) {
            self.ctrlView.hidden = NO;
        }
    }];
    if (GCMouse.current != nil) {
        [self registerMouseCallbacks:GCMouse.current];
    }
    

    // TODO: deal with multiple controllers by letting users decide which one to use?
    self.controllerConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"Input: Controller connected!");
        GCController* controller = note.object;
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:controller];
        self.mousePointerView.hidden = isGrabbing;
        virtualMouseEnabled = YES;
        if (getPrefBool(@"control.hardware_hide")) {
            self.ctrlView.hidden = YES;
        }
    }];
    self.controllerDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"Input: Controller disconnected!");
        GCController* controller = note.object;
        [ControllerInput unregisterControllerCallbacks:controller];
        if (getPrefBool(@"control.hardware_hide")) {
            self.ctrlView.hidden = NO;
        }
    }];
    if (GCController.controllers.count == 1) {
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:GCController.controllers.firstObject];
    }

    [self.rootView addSubview:self.inputTextField];

    [self performSelector:@selector(initCategory_LogView)];

    // [self setPreferredFramesPerSecond:1000];
    [self updateJetsamControl];
    [self updatePreferenceChanges];
    [self loadCustomControls];

    if (UIApplication.sharedApplication.connectedScenes.count > 1 &&
      getPrefBool(@"video.fullscreen_airplay")) {
        [self switchToExternalDisplay];
    }

    [self launchMinecraft];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setNeedsUpdateOfPrefersPointerLocked];
}

- (void)updateAudioSettings {
    NSError *sessionError = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // Deactivate before changing category to avoid audio glitches
    [session setActive:NO error:nil];

    AVAudioSessionCategory category;
    AVAudioSessionCategoryOptions options = 0;
    if(getPrefBool(@"video.allow_microphone")) {
        category = AVAudioSessionCategoryPlayAndRecord;
        options |= AVAudioSessionCategoryOptionAllowAirPlay | AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionDefaultToSpeaker;
    } else {
        category = AVAudioSessionCategoryPlayback;
    }
    if(!getPrefBool(@"video.silence_other_audio")) {
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    [session setCategory:category withOptions:options error:&sessionError];

    if(getPrefBool(@"video.allow_microphone")) {
        [session setPreferredSampleRate:48000.0 error:&sessionError];
        [session setPreferredIOBufferDuration:0.005 error:&sessionError];
    }

    [session setActive:YES error:&sessionError];

    if(getPrefBool(@"video.allow_microphone")) {
        [self selectMicrophoneSource];
    }
}

- (void)selectMicrophoneSource {
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;

    AVAudioSessionPortDescription *builtInMic = nil;
    for (AVAudioSessionPortDescription *input in session.availableInputs) {
        if ([input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            builtInMic = input;
            break;
        }
    }

    if (!builtInMic || builtInMic.dataSources.count == 0) {
        NSLog(@"[MicSource] No built-in mic or no data sources available");
        return;
    }

    NSString *source = getPrefObject(@"video.microphone_source");
    NSArray<NSString *> *preferredOrder = nil;
    if (!source || [source isEqualToString:@"auto"]) {
        preferredOrder = @[@"Front", @"Bottom", @"Back"];
    } else if ([source isEqualToString:@"front"]) {
        preferredOrder = @[@"Front"];
    } else if ([source isEqualToString:@"bottom"]) {
        preferredOrder = @[@"Bottom"];
    } else if ([source isEqualToString:@"back"]) {
        preferredOrder = @[@"Back"];
    }

    for (NSString *prefName in preferredOrder) {
        for (AVAudioSessionDataSourceDescription *dataSource in builtInMic.dataSources) {
            if ([dataSource.dataSourceName localizedCaseInsensitiveContainsString:prefName]) {
                [session setPreferredInput:builtInMic error:&error];
                [builtInMic setPreferredDataSource:dataSource error:&error];
                NSLog(@"[MicSource] Selected: %@", dataSource.dataSourceName);
                return;
            }
        }
    }

    NSLog(@"[MicSource] No matching data source found, using system default");
}

- (void)updateJetsamControl {
    if (!getEntitlementValue(@"com.apple.private.memorystatus")) {
        return;
    }
    // More 1024MB is necessary for other memory regions (native, Java GC, etc.)
    int limit = getPrefInt(@"java.allocated_memory") + 1024;
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), limit, NULL, 0) == -1) {
        NSLog(@"Failed to set Jetsam task limit: error: %s", strerror(errno));
    } else {
        NSLog(@"Successfully set Jetsam task limit");
    }
}

- (void)updatePreferenceChanges {
    // Update UITextField auto correction
    if (getPrefBool(@"debug.debug_auto_correction")) {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeDefault;
    } else {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    }

    BOOL gyroEnabled = getPrefBool(@"control.gyroscope_enable");
    BOOL gyroInvertX = getPrefBool(@"control.gyroscope_invert_x_axis");
    int gyroSensitivity = getPrefInt(@"control.gyroscope_sensitivity");
    [GyroInput updateSensitivity:gyroEnabled?gyroSensitivity:0 invertXAxis:gyroInvertX];

    self.mouseSpeed = getPrefFloat(@"control.mouse_speed") / 100.0;

    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;

    // Update virtual mouse scale
    CGFloat mouseScale = getPrefFloat(@"control.mouse_scale") / 100.0;
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18.0 * mouseScale, 27 * mouseScale);
    self.mousePointerView.frame = virtualMouseFrame;

    self.shouldHideControlsFromRecording = getPrefFloat(@"control.recording_hide");
    [self.ctrlView hideViewFromCapture:self.shouldHideControlsFromRecording];
    self.ctrlView.frame = getSafeArea(self.view.frame);

    // Update gestures state
    self.slideableHotbar = getPrefBool(@"control.slideable_hotbar");
    self.enableMouseGestures = getPrefBool(@"control.gesture_mouse");
    self.enableHotbarGestures = getPrefBool(@"control.gesture_hotbar");
    self.shouldTriggerHaptic = !getPrefBool(@"control.disable_haptics");

    self.scrollPanGesture.enabled = self.enableMouseGestures;
    self.doubleTapGesture.enabled = self.enableHotbarGestures;
    self.longPressGesture.minimumPressDuration = getPrefFloat(@"control.press_duration") / 1000.0;

    // Update audio settings
    [self updateAudioSettings];
    // Update resolution
    [self updateSavedResolution];
    // Update performance HUD visibility
    if (@available(iOS 16, tvOS 16, *)) {
        if ([self.surfaceView.layer isKindOfClass:CAMetalLayer.class]) {
            BOOL perfHUDEnabled = getPrefBool(@"video.performance_hud");
            ((CAMetalLayer *)self.surfaceView.layer).developerHUDProperties = perfHUDEnabled ? @{@"mode": @"default"} : nil;
        }
    }
    // Update pointer lock state
    [self setNeedsUpdateOfPrefersPointerLocked];
}

- (void)updateSavedResolution {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
        self.screenScale = scene.screen.scale;
        if (scene.session.role != UIWindowSceneSessionRoleApplication) {
            break;
        }
    }

    if (self.surfaceView.superview != nil) {
        self.surfaceView.frame = self.surfaceView.superview.frame;
    }

    resolutionScale = getPrefFloat(@"video.resolution") / 100.0;
    self.surfaceView.layer.contentsScale = self.screenScale * resolutionScale;

    physicalWidth = roundf(self.surfaceView.frame.size.width * self.screenScale);
    physicalHeight = roundf(self.surfaceView.frame.size.height * self.screenScale);
    windowWidth = roundf(physicalWidth * resolutionScale);
    windowHeight = roundf(physicalHeight * resolutionScale);
    // Resolution should not be odd
    if ((windowWidth % 2) != 0) {
        --windowWidth;
    }
    if ((windowHeight % 2) != 0) {
        --windowHeight;
    }
    CallbackBridge_nativeSendScreenSize(windowWidth, windowHeight);
}

- (void)updateControlHiddenState:(BOOL)hide {
    for (UIView *view in self.ctrlView.subviews) {
        ControlButton *button = (ControlButton *)view;
        if (!button.canBeHidden) continue;
        BOOL hidden = hide || !(
            (isGrabbing && [button.properties[@"displayInGame"] boolValue]) ||
            (!isGrabbing && [button.properties[@"displayInMenu"] boolValue]));
        if (!hidden && ![button isKindOfClass:ControlSubButton.class]) {
            button.hidden = hidden;
            if ([button isKindOfClass:ControlDrawer.class]) {
                [(ControlDrawer *)button restoreButtonVisibility];
            }
        } else if (hidden) {
            button.hidden = hidden;
        }
    }
}

- (void)updateGrabState {
    // Update cursor position
    if (isGrabbing == JNI_TRUE) {
        CGFloat screenScale = self.surfaceView.layer.contentsScale;
        CallbackBridge_nativeSendCursorPos(ACTION_DOWN, lastVirtualMousePoint.x * screenScale, lastVirtualMousePoint.y * screenScale);
        virtualMouseFrame.origin.x = self.view.frame.size.width / 2;
        virtualMouseFrame.origin.y = self.view.frame.size.height / 2;
        self.mousePointerView.frame = virtualMouseFrame;
    }
    self.scrollPanGesture.enabled = !isGrabbing;
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
    [self setNeedsUpdateOfPrefersPointerLocked];

    // Update buttons visibility
    [self updateControlHiddenState:NO];
}

- (void)installSDLSurfaceWatch {
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath
                      stringByAppendingPathComponent:@"libSDL3.dylib"];
    void *sdl = dlopen(path.UTF8String, RTLD_NOW);   // already loaded by the game — refcount++
    if (!sdl) {
        NSLog(@"[SDL Watch] dlopen libSDL3 failed: %s", dlerror());
    } else {
        SDL3_AddEventWatchFn addWatch = (SDL3_AddEventWatchFn)dlsym(sdl, "SDL_AddEventWatch");
        g_sdlDelWatch = (SDL3_DelEventWatchFn)dlsym(sdl, "SDL_DelEventWatch"); // not exported from this dylib — NULL expected
        if (!addWatch) {   // was !addWatch || !g_sdlDelWatch — non-exported Del killed the whole watch
            NSLog(@"[SDL Watch] dlsym(SDL_AddEventWatch) failed");
        } else {
            if (g_sdlFilter) {   // re-registration: remove the old filter first
                g_sdlDelWatch(g_sdlFilter, NULL);
                g_sdlFilter = NULL;
            }
            g_sdlSurfaceVC = self;
            bool ok = addWatch(SurfaceSDLSurfaceEventFilter, NULL);
            g_sdlFilter = ok ? SurfaceSDLSurfaceEventFilter : NULL;
            NSLog(@"[SDL Watch] SDL_AddEventWatch %@", ok ? @"registered" : @"failed");
        }
    }

    // Safety fallback: if no window event arrives (e.g. the renderer creates no
    // SDL window), sync once after 5s so coordinates are never left stale.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_sdlSafetyTimer) {
            dispatch_source_cancel(g_sdlSafetyTimer);
        }
        g_sdlSafetyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                  dispatch_get_main_queue());
        dispatch_source_set_timer(g_sdlSafetyTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER, 0);
        __weak SurfaceViewController *weakSelf = self;
        dispatch_source_set_event_handler(g_sdlSafetyTimer, ^{
            if (!g_sdlSurfaceSynced) {
                NSLog(@"[SDL Watch] No SDL window event within 5s — fallback sync");
                [weakSelf sdlSurfaceReady:NO];
            } else {
                // A real event already synced the surface; just drop the timer.
                g_sdlSafetyTimer = NULL;
            }
        });
        dispatch_resume(g_sdlSafetyTimer);
    });
}

- (void)uninstallSDLSurfaceWatch {
    if (g_sdlDelWatch && g_sdlFilter) {
        g_sdlDelWatch(g_sdlFilter, NULL);
    }
    g_sdlFilter = NULL;
    g_sdlSurfaceVC = nil;
    if (g_sdlSafetyTimer) {
        dispatch_source_cancel(g_sdlSafetyTimer);
        g_sdlSafetyTimer = NULL;
    }
}

- (void)sdlSurfaceReady:(BOOL)fromEvent {
    NSLog(@"[SDL Watch] surface ready via %@", fromEvent ? @"SDL event" : @"safety fallback");
    // First firing (real event or safety fallback) stops the timer and dumps the
    // hierarchy once for the z-order diagnosis. Runs on the main thread.
    if (g_sdlSafetyTimer) {
        dispatch_source_cancel(g_sdlSafetyTimer);
        g_sdlSafetyTimer = NULL;
    }
    // Diagnostic: one-shot dump — the safety fallback already covers a fresh launch,
    // and dumping on every SDL window event (8x in 8s) was measurable heaviness.
    if (!g_sdlHierarchyDumped) {
        g_sdlHierarchyDumped = YES;
        [self dumpViewHierarchyDebug];
    }
    [self updateSavedResolution];   // sync coordinates at true surface-ready time
    [self fixSDLViewZOrder];        // keep touch controls above the SDL view
    [self configureSDLWindowLevel]; // Approach B: drop the SDL window below the launcher
    // WINDOW_SHOWN can fire a beat before SDL's UIWindow lands in the scene's
    // windows list, and SDL_ShowWindow may re-normalize the level afterwards —
    // re-apply shortly so the window can't stay on top of the controls.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self configureSDLWindowLevel];
    });
    g_sdlSurfaceSynced = YES;
}

// [Amethyst diag] Compact window-stack snapshot for the repeating diagnostic timer:
// answers (a) does the SDL window exist yet, (b) is it visible/key, (c) where is it
// in the z-order vs the launcher window, (d) has a CAMetalLayer attached to its view.
- (void)logSDLWindowStatus {
    NSArray<UIWindow *> *windows = nil;
    if (@available(iOS 13.0, *)) {
        NSMutableArray *all = [NSMutableArray array];
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                [all addObjectsFromArray:((UIWindowScene *)s).windows];
            }
        }
        windows = all;
    } else {
        windows = UIApplication.sharedApplication.windows;
    }
    NSLog(@"[SDL Diag] windows on screen: %lu (last == frontmost)", (unsigned long)windows.count);
    for (NSUInteger i = 0; i < windows.count; i++) {
        UIWindow *w = windows[i];
        Class sdlVC = NSClassFromString(@"SDL_uikitviewcontroller");
        BOOL isSDL = (sdlVC && [w.rootViewController isKindOfClass:sdlVC]);
        NSLog(@"[SDL Diag]   [%lu] %@ %@ rvc=%@ hidden=%d key=%d level=%.2f frame=%@",
              (unsigned long)i,
              isSDL ? @"<== SDL" : @"",
              NSStringFromClass(w.class),
              NSStringFromClass(w.rootViewController.class),
              w.hidden, w.isKeyWindow, w.windowLevel,
              NSStringFromCGRect(w.frame));
        if (isSDL) {
            for (UIView *v in w.rootViewController.view.subviews) {
                NSLog(@"[SDL Diag]       subview %@ layer=%@ frame=%@",
                      NSStringFromClass(v.class),
                      NSStringFromClass(v.layer.class),
                      NSStringFromCGRect(v.frame));
            }
        }
    }
}

// [Amethyst] Find the separate window SDL3 created for the game (rootVC is
// SDL_uikitviewcontroller). Returns nil for old MC builds that render into our
// own views (no SDL window) — those stay in the GLFW path.
- (UIWindow *)findSDLWindow {
    NSArray<UIWindow *> *windows = nil;
    if (@available(iOS 13.0, *)) {
        NSMutableArray *all = [NSMutableArray array];
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                [all addObjectsFromArray:((UIWindowScene *)s).windows];
            }
        }
        windows = all;
    } else {
        windows = UIApplication.sharedApplication.windows;
    }
    Class sdlVC = NSClassFromString(@"SDL_uikitviewcontroller");
    for (UIWindow *w in windows) {
        if (sdlVC && [w.rootViewController isKindOfClass:sdlVC]) {
            return w;
        }
    }
    return nil;
}

// [Amethyst] Approach B (window level): keep the SDL/Minecraft window BELOW the
// launcher window so on-screen controls (ctrlView) stay above it and tappable.
// Idempotent — safe to run on every SDL window event / rotation.
- (void)configureSDLWindowLevel {
    // UIKit window properties must be touched on the main thread. sdlSurfaceReady:
    // already hops here from its event-filter caller, but guard anyway so a future
    // caller (diag timer, safety fallback) can never touch UIWindow off-main.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self configureSDLWindowLevel];
        });
        return;
    }
    NSLog(@"[SDL Config] configureSDLWindowLevel called");
    UIWindow *sdlWin = [self findSDLWindow];
    NSLog(@"[SDL Config] found SDL window: %@, current level: %.2f",
          sdlWin, sdlWin ? sdlWin.windowLevel : -999.0);
    if (!sdlWin) {
        NSLog(@"[SDL Config] SDL window not found yet — no-op (old MC, or still creating)");
        return;
    }

    if (sdlWin.windowLevel >= UIWindowLevelNormal) {
        sdlWin.windowLevel = UIWindowLevelNormal - 1;   // SDL window BELOW ours
        NSLog(@"[SDL Config] set SDL window level to: %.2f", sdlWin.windowLevel);
    } else {
        NSLog(@"[SDL Config] SDL window already below ours (level %.2f)", sdlWin.windowLevel);
    }
    UIWindow *appWin = self.view.window;
    appWin.windowLevel = UIWindowLevelNormal;           // ours: Normal (belt & braces)
    appWin.backgroundColor = [UIColor clearColor];      // window is transparent; avoid a solid layer
    self.view.backgroundColor = [UIColor clearColor];
    self.rootView.backgroundColor = [UIColor clearColor];
    self.touchView.backgroundColor = [UIColor clearColor];  // remove the black backdrop so the
                                                            // SDL window (below) shows through
    // ctrlView (ControlLayout, ~763x390) is neither an ancestor above self.view nor
    // self.view/rootView/touchView, so no earlier transparency pass touched it. It's the
    // view closest to the user: opaque=1 with no clear backgroundColor paints black
    // between the control buttons (ControlButton are opaque=0 individually) — the actual
    // "black screen" sitting on top of the SDL window. Buttons' own rendering is untouched.
    self.ctrlView.opaque = NO;
    self.ctrlView.backgroundColor = [UIColor clearColor];
    // clearColor alone doesn't guarantee transparency: UIView.opaque defaults to YES and
    // UIKit may still rasterize the layer as fully opaque (black/undefined on Metal).
    // Mark every layer in the chain explicitly transparent.
    appWin.opaque = NO;
    self.view.opaque = NO;
    self.rootView.opaque = NO;
    self.touchView.opaque = NO;
    // UITransitionView and UIDropShadowView (system wrappers UIKit inserts between the
    // UIWindow and rootViewController.view) are opaque=1 by default, so the transparency
    // chain was breaking ABOVE self.view. Walk up to the window and clear every ancestor
    // (future-proof: not tied to specific class names).
    {
        UIView *ancestor = self.view.superview;
        while (ancestor && ![ancestor isKindOfClass:UIWindow.class]) {
            ancestor.opaque = NO;
            ancestor.backgroundColor = [UIColor clearColor];
            ancestor = ancestor.superview;
        }
    }
    // Stage 1: touchView no longer takes touches, so empty-zone touches can fall
    // through. rootView/ctrlView stay interactive (controls must keep working).
    self.touchView.userInteractionEnabled = NO;

    self.surfaceView.hidden = YES;                  // old GLFW surface unused in SDL mode

    g_sdlInputActive = YES;                         // extern flag -> input_bridge routes keys to SDL
    [self logSDLWindowStatus];                      // diag: confirm z-order after the level change

    // One-shot confirmation: dumpViewHierarchyDebug in sdlSurfaceReady runs BEFORE this
    // method, and the 5s safety fallback used to fire while findSDLWindow was still nil
    // (early return) — so the only full hierarchy dump in the log predates the
    // transparency fix. Dump once here, post-activation, to verify the real opaque/bg
    // state after every fix has been applied.
    if (!g_sdlPostActivationDumped) {
        g_sdlPostActivationDumped = YES;
        [self dumpViewHierarchyDebug];
    }
}

// [Amethyst] Poll until SDL mode is really active (no fixed cap). The earlier diag timer
// stopped after 6×10s, but Vulkan init can exceed that; after it stopped, the only thing
// left that re-fired configureSDLWindowLevel was a rotation (SDL_EVENT_WINDOW_RESIZED) —
// which is why input "came alive" only after the first rotate. Here: every 1s, if the SDL
// window exists, apply the level (and activate the whole SDL-mode state); stop as soon as
// g_sdlInputActive flips — that's the success signal.
- (void)pollUntilSDLReady {
    UIWindow *sdlWin = [self findSDLWindow];
    if (sdlWin) {
        // Diagnostic: a pointer change means SDL recreated its window, so the level would
        // have to be re-applied to the fresh instance (forceshow-patch issue, not timing).
        if ((__bridge void *)sdlWin != g_lastSDLWindowPtr) {
            NSLog(@"[SDL Config] окно СМЕНИЛОСЬ: было %p, стало %p",
                  g_lastSDLWindowPtr, (__bridge void *)sdlWin);
            g_lastSDLWindowPtr = (__bridge void *)sdlWin;
        }
        [self configureSDLWindowLevel];
        if (g_sdlInputActive) {
            NSLog(@"[SDL Config] SDL-режим активирован без поворота экрана");
            return; // success — stop polling
        }
    } else {
        NSLog(@"[SDL Config] poll: окно ещё не создано");
    }
    __weak SurfaceViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf pollUntilSDLReady];
    });
}

- (void)launchMinecraft {
    // SDL3 iOS builds gate SDL_Init on SDL_SetMainReady() (SDL_MAIN_NEEDED is
    // always defined for iOS unless SDL_MAIN_HANDLED was set when the dylib was
    // built). The game calls SDL_Init from inside the JVM, so prepare SDL on the
    // main thread here — before the JVM boots — otherwise SDL_Init fails with
    // "Application didn't initialize properly, did you include SDL_main.h...".
    init_loadSDL3MainReady();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int minVersion = [self.metadata[@"javaVersion"][@"majorVersion"] intValue];
        if (minVersion == 0) {
            minVersion = [self.metadata[@"javaVersion"][@"version"] intValue];
        }
        launchJVM(
            BaseAuthenticator.current.authData[@"username"],
            self.metadata,
            windowWidth, windowHeight,
            minVersion
        );
    });

    // [Amethyst diag] Register the SDL window-event watch in parallel with the
    // JVM boot. launchJVM() blocks its thread until the JVM exits, so a dispatch
    // after launchJVM would never run during gameplay — the event watch and the
    // 5s safety timer must be live while the game's SDL window exists.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installSDLSurfaceWatch];
    });

    // [Amethyst] Poll every 1s until SDL mode is actually active. configureSDLWindowLevel
    // early-returns while the SDL window isn't in the scene's window list yet (Vulkan/Metal
    // init can take tens of seconds), so a fixed 6×10s diag timer could stop before the
    // window ever appears — and rotation was the only remaining re-trigger. This unbounded
    // poll removes the "rotate once to fix it" requirement. Cheap: stops as soon as
    // g_sdlInputActive flips.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self pollUntilSDLReady];
    });
}

- (void)fixSDLViewZOrder {
    NSLog(@"[SDL Z-Order Fix] Checking view hierarchy...");
    // Search for SDL-created views and ensure ctrlView sits above touchView — but NOT
    // blindly at the very top. rootView's natural order is edge-strip -> touchView ->
    // ctrlView -> inputTextField -> UILayoutContainerView (settings/log/swipe menu must
    // stay above the game buttons). bringSubviewToFront permanently pinned the buttons
    // over the menu screen; inserting only above touchView keeps "controls above the SDL
    // view" without covering it.
    if (self.ctrlView.superview == self.rootView && self.touchView.superview == self.rootView) {
        NSInteger ctrlIndex = [self.rootView.subviews indexOfObject:self.ctrlView];
        NSInteger touchIndex = [self.rootView.subviews indexOfObject:self.touchView];
        if (ctrlIndex < touchIndex) {
            NSLog(@"[SDL Z-Order Fix] ctrlView ниже touchView — поднимаем ровно над ним");
            [self.rootView insertSubview:self.ctrlView aboveSubview:self.touchView];
        } else {
            NSLog(@"[SDL Z-Order Fix] ctrlView уже выше touchView, остальной порядок не трогаем");
        }
    }

    // Also ensure ctrlView is not accidentally hidden
    if (self.ctrlView.hidden && !self.toggleHidden) {
        NSLog(@"[SDL Z-Order Fix] ctrlView was hidden, restoring visibility");
        self.ctrlView.hidden = NO;
    }
}

- (void)dumpViewHierarchyDebug {
    SDLDiagLog(@"========== VIEW HIERARCHY DEBUG START ==========");
    SDLDiagLog(@"[DEBUG] SurfaceViewController.view frame: %@", NSStringFromCGRect(self.view.frame));
    SDLDiagLog(@"[DEBUG] SurfaceViewController.view.window: %@", self.view.window);
    SDLDiagLog(@"[DEBUG] screenScale: %.2f, resolutionScale: %.2f", self.screenScale, resolutionScale);
    SDLDiagLog(@"[DEBUG] windowWidth: %d, windowHeight: %d", windowWidth, windowHeight);
    SDLDiagLog(@"[DEBUG] physicalWidth: %d, physicalHeight: %d", physicalWidth, physicalHeight);

    SDLDiagLog(@"\n[DEBUG] === rootView ===");
    SDLDiagLog(@"frame: %@  interactive:%d hidden:%d  subviews:%lu",
               NSStringFromCGRect(self.rootView.frame),
               self.rootView.userInteractionEnabled, self.rootView.hidden,
               (unsigned long)self.rootView.subviews.count);

    SDLDiagLog(@"\n[DEBUG] === touchView ===");
    SDLDiagLog(@"frame: %@  interactive:%d hidden:%d  subviews:%lu",
               NSStringFromCGRect(self.touchView.frame),
               self.touchView.userInteractionEnabled, self.touchView.hidden,
               (unsigned long)self.touchView.subviews.count);

    SDLDiagLog(@"\n[DEBUG] === surfaceView (GameSurfaceView) ===");
    SDLDiagLog(@"frame: %@ interactive:%d hidden:%d", NSStringFromCGRect(self.surfaceView.frame),
               self.surfaceView.userInteractionEnabled, self.surfaceView.hidden);
    SDLDiagLog(@"layer.class: %@", NSStringFromClass([self.surfaceView.layer class]));
    SDLDiagLog(@"layer.contentsScale: %.2f  layer.opaque:%d", self.surfaceView.layer.contentsScale, self.surfaceView.layer.opaque);

    SDLDiagLog(@"\n[DEBUG] === ctrlView (ControlLayout; hitTest: returns nil for bg) ===");
    SDLDiagLog(@"frame: %@  interactive:%d hidden:%d  subviews:%lu",
               NSStringFromCGRect(self.ctrlView.frame),
               self.ctrlView.userInteractionEnabled, self.ctrlView.hidden,
               (unsigned long)self.ctrlView.subviews.count);

    // ---- Window stack. SDL3 renders into ITS OWN UIWindow (data.uiwindow), separate
    // from ours, so walking self.view.window can never see the SDL view. Enumerate ALL
    // windows. UIApplication/UIWindowScene.windows are back-to-front: index 0 is the
    // backmost window, the LAST index is the FRONTMOST = hit-tested first = the one that
    // eats touches. The key touch-routing questions are answered per window below.
    SDLDiagLog(@"\n[DEBUG] === WINDOW STACK (touch-routing diagnosis) ===");
    NSMutableArray<UIWindow *> *allWindows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [allWindows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
    } else {
        [allWindows addObjectsFromArray:UIApplication.sharedApplication.windows];
    }

    NSUInteger winCount = allWindows.count;
    SDLDiagLog(@"[DEBUG] windows on screen: %lu (last index == FRONTMOST == hit-test priority)",
               (unsigned long)winCount);
    for (NSUInteger i = 0; i < winCount; i++) {
        UIWindow *w = allWindows[i];
        BOOL isFront = (i == winCount - 1);
        SDLDiagLog(@"[DEBUG] --- WINDOW[%lu]%@%@ ---",
                   (unsigned long)i,
                   isFront ? @"  [FRONTMOST·hit-test-first]" : @"",
                   w.isKeyWindow ? @"  [isKeyWindow]" : @"");
        SDLDiagLog(@"  class: %@", NSStringFromClass(w.class));
        SDLDiagLog(@"  frame: %@  bounds: %@", NSStringFromCGRect(w.frame), NSStringFromCGRect(w.bounds));
        SDLDiagLog(@"  hidden: %d  alpha: %.3f  layer.opaque: %d",
                   w.hidden, w.alpha, w.layer.opaque);
        SDLDiagLog(@"  userInteractionEnabled: %d  isKeyWindow: %d  windowLevel: %.3f",
                   w.userInteractionEnabled, w.isKeyWindow, w.windowLevel);
        SDLDiagLog(@"  backgroundColor: %@", [w.backgroundColor description]);
        UIViewController *rvc = w.rootViewController;
        SDLDiagLog(@"  rootViewController: %@", rvc ? NSStringFromClass(rvc.class) : @"(nil)");
        UIView *rv = rvc.view;  // may be nil before load
        if (rv) {
            SDLDiagLog(@"    rootView.class: %@  hidden:%d interactive:%d alpha:%.2f opaque:%d bg:%@",
                       NSStringFromClass(rv.class), rv.hidden, rv.userInteractionEnabled,
                       rv.alpha, rv.layer.opaque, [rv.backgroundColor description]);
        }
        SDLDiagLog(@"  [tree]");
        [self dumpViewRecursive:w level:1 label:@"UIWindow"];
        SDLDiagLog(@"  [SDL-search]");
        [self findSDLViewsIn:w];
    }

    SDLDiagLog(@"========== VIEW HIERARCHY DEBUG END ==========\n");
}

- (void)dumpViewRecursive:(UIView *)view level:(int)level label:(NSString *)label {
    if (!view) return;

    NSString *indent = [@"" stringByPaddingToLength:level * 2 withString:@" " startingAtIndex:0];
    NSString *className = NSStringFromClass([view class]);
    CGRect frame = view.frame;
    CGFloat scale = (view.layer.contentsScale > 0) ? view.layer.contentsScale : 1.0;

    BOOL isOurView = (view == self.view || view == self.rootView || view == self.touchView ||
                      view == self.surfaceView || view == self.ctrlView);
    NSString *marker = isOurView ? @" ← OUR VIEW" : @"";

    SDLDiagLog(@"%s[%d] %@: %@ frame=%@ scale=%.2f hidden=%d interact=%d alpha=%.2f opaque=%d subviews=%lu%@",
          indent.UTF8String, level,
          label.length > 0 ? label : className,
          className,
          NSStringFromCGRect(frame),
          scale,
          view.hidden, view.userInteractionEnabled, view.alpha, view.layer.opaque,
          (unsigned long)view.subviews.count,
          marker);

    // Special handling for CALayer info
    if ([view.layer isKindOfClass:[CAMetalLayer class]]) {
        SDLDiagLog(@"%@   └─ CAMetalLayer (Metal render path) detected!", indent);
    }

    for (int i = 0; i < view.subviews.count; i++) {
        UIView *subview = view.subviews[i];
        [self dumpViewRecursive:subview level:level + 1 label:[NSString stringWithFormat:@"subview[%d]", i]];
    }
}

- (void)findSDLViewsIn:(UIView *)rootView {
    [self searchSDLViewRecursive:rootView path:@""];
}

- (void)searchSDLViewRecursive:(UIView *)view path:(NSString *)path {
    if (!view) return;

    NSString *className = NSStringFromClass([view class]);
    NSString *currentPath = path.length > 0 ? [NSString stringWithFormat:@"%@ > %@", path, className] : className;

    // Check if this looks like an SDL view
    if ([className containsString:@"SDL"] ||
        [className containsString:@"sdl"] ||
        [className hasPrefix:@"_"]) {  // Private UIKit classes often start with _

        SDLDiagLog(@"[SDL CANDIDATE] %@", currentPath);
        SDLDiagLog(@"  class: %@  superview: %@",
                   className, NSStringFromClass([view.superview class]));
        SDLDiagLog(@"  frame: %@  hidden: %d  interactive: %d  alpha: %.2f  opaque: %d",
                   NSStringFromCGRect(view.frame), view.hidden,
                   view.userInteractionEnabled, view.alpha, view.layer.opaque);
        SDLDiagLog(@"  layer.class: %@  contentsScale: %.2f  bg: %@",
                   NSStringFromClass([view.layer class]), view.layer.contentsScale,
                   view.layer.backgroundColor ? @"has-bg" : @"clear");
        SDLDiagLog(@"  contentScaleFactor: %.2f", view.contentScaleFactor);

        // z-order within the app window (only meaningful if the SDL view is our child)
        if (view.superview == self.rootView) {
            NSInteger sdlIndex = [self.rootView.subviews indexOfObject:view];
            NSInteger ctrlIndex = [self.rootView.subviews indexOfObject:self.ctrlView];
            SDLDiagLog(@"  Z-order: SDL at index %ld, ctrlView at index %ld (higher = on top)", (long)sdlIndex, (long)ctrlIndex);
        }
    }

    for (UIView *subview in view.subviews) {
        [self searchSDLViewRecursive:subview path:currentPath];
    }
}

- (void)loadCustomControls {
    self.edgeGesture.enabled = YES;
    [self.swipeableButtons removeAllObjects];
    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    [self.ctrlView loadControlFile:controlFile];

    ControlButton *menuButton;
    for (ControlButton *button in self.ctrlView.subviews) {
        BOOL isSwipeable = [button.properties[@"isSwipeable"] boolValue];

        button.canBeHidden = YES;
        BOOL isMenuButton = NO;
        for (int i = 0; i < 4; i++) {
            int keycodeInt = [button.properties[@"keycodes"][i] intValue];
            button.canBeHidden &= keycodeInt != SPECIALBTN_TOGGLECTRL && keycodeInt != SPECIALBTN_VIRTUALMOUSE;
            if (keycodeInt == SPECIALBTN_MENU) {
                menuButton = button;
            }
        }

        [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(executebtn_up_inside:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(executebtn_up_outside:) forControlEvents:UIControlEventTouchUpOutside];

        if (isSwipeable) {
            UIPanGestureRecognizer *panRecognizerButton = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(executebtn_swipe:)];
            panRecognizerButton.delegate = self;
            [button addGestureRecognizer:panRecognizerButton];
            [self.swipeableButtons addObject:button];
        }
    }

    [self updateControlHiddenState:self.toggleHidden];

    if (menuButton) {
        NSMutableArray *items = [NSMutableArray new];
        for (int i = 0; i < self.menuArray.count; i++) {
            UIAction *item = [UIAction actionWithTitle:localize(self.menuArray[i], nil) image:nil identifier:nil
                handler:^(id action) {
                    NSLog(@"[Menu Diag] пункт меню выбран: %d", i);
                    [self didSelectMenuItem:i];
                }];
            [items addObject:item];
        }
        menuButton.menu = [UIMenu menuWithTitle:@"" image:nil identifier:nil
            options:UIMenuOptionsDisplayInline children:items];
        menuButton.showsMenuAsPrimaryAction = YES;
        self.edgeGesture.enabled = NO;
    }

    // [Menu Diag] Truth about the swipe/menu path: does the active profile contain a
    // SPECIALBTN_MENU button, and does the edge gesture end up enabled after it? Placed at
    // the END of loadCustomControls so edgeGesture.enabled is the final value (the
    // menu-button block above sets it to NO), not the YES from the top of the method.
    NSLog(@"[Menu Diag] menuButton найдена в профиле: %@ (frame=%@)",
          menuButton ? @"ДА" : @"НЕТ",
          menuButton ? NSStringFromCGRect(menuButton.frame) : @"n/a");
    NSLog(@"[Menu Diag] edgeGesture.enabled итог: %d", self.edgeGesture.enabled);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.rootView.bounds = CGRectMake(0, 0, size.width + 30.0, size.height);

        CGRect frame = self.view.frame;
        frame.size = size;
        self.touchView.frame = frame;
        self.inputTextField.frame = CGRectMake(0, -32.0, size.width, 30.0);
        [self viewWillTransitionToSize_Navigation:frame];

        // Update custom controls button position
        self.ctrlView.frame = getSafeArea(self.view.frame);
        [self.ctrlView.subviews makeObjectsPerformSelector:@selector(update)];

        // Update game resolution
        [self updateSavedResolution];
        [GyroInput updateOrientation];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        virtualMouseFrame = self.mousePointerView.frame;
        // [Amethyst] Belt & braces: rotation used to be the only re-trigger for
        // configureSDLWindowLevel (via SDL_EVENT_WINDOW_RESIZED). Re-apply explicitly so
        // the SDL window level / SDL-mode activate even if the SDL event didn't arrive.
        [self configureSDLWindowLevel];
    }];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - Input: send touch utilities

- (BOOL)isTouchInactive:(UITouch *)touch {
    return touch == nil || touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled;
}

- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event
{
    CGFloat screenScale = self.screenScale;
    if (!isGrabbing) {
        screenScale *= resolutionScale;
        if (virtualMouseEnabled) {
            if (event == ACTION_MOVE) {
                virtualMouseFrame.origin.x += (location.x - lastVirtualMousePoint.x) * self.mouseSpeed;
                virtualMouseFrame.origin.y += (location.y - lastVirtualMousePoint.y) * self.mouseSpeed;
            } else if (event == ACTION_MOVE_MOTION) {
                event = ACTION_MOVE;
                virtualMouseFrame.origin.x += location.x * self.mouseSpeed;
                virtualMouseFrame.origin.y += location.y * self.mouseSpeed;
            }
            virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x, 0, self.surfaceView.frame.size.width);
            virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y, 0, self.surfaceView.frame.size.height);
            lastVirtualMousePoint = location;
            self.mousePointerView.frame = virtualMouseFrame;
            CallbackBridge_nativeSendCursorPos(event, virtualMouseFrame.origin.x * screenScale, virtualMouseFrame.origin.y * screenScale);
            return;
        }
        lastVirtualMousePoint = location;
    }
    CallbackBridge_nativeSendCursorPos(event, location.x * screenScale, location.y * screenScale);
}

#pragma mark - Input: on-surface functions

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)keyboardGesture:(UIGestureRecognizer*)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        if (self.inputTextField.isFirstResponder) {
            [self.inputTextField resignFirstResponder];
            self.inputTextField.alpha = 1.0f;
        } else {
            [self.inputTextField becomeFirstResponder];
            // Insert an undeletable space
            self.inputTextField.text = @" ";
        }
    }
}

- (void)sendTouchEvent:(UITouch *)touchEvent withUIEvent:(UIEvent *)uievent withEvent:(int)event
{
    CGPoint locationInView = [touchEvent locationInView:self.rootView];

    //if (touchEvent.view == self.surfaceView) {
        switch (event) {
            case ACTION_DOWN:
                self.clickRange = CGRectMake(locationInView.x - 2, locationInView.y - 2, 5, 5);
                self.shouldTriggerClick = YES;
                break;

            case ACTION_MOVE:
                if (self.shouldTriggerClick && !CGRectContainsPoint(self.clickRange, locationInView)) {
                    self.shouldTriggerClick = NO;
                }
                break;
        }

        if (touchEvent == self.hotbarTouch && self.slideableHotbar && ![self isTouchInactive:self.hotbarTouch]) {
            CGFloat screenScale = [[UIScreen mainScreen] scale];
            int slot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
            if (slot != -1 && currentHotbarSlot != slot && (event == ACTION_DOWN || currentHotbarSlot != -1)) {
                currentHotbarSlot = slot;
                CallbackBridge_nativeSendKey(slot, 0, 1, 0);
                CallbackBridge_nativeSendKey(slot, 0, 0, 0);
                return;
            } /* else if ((event == ACTION_MOVE || event == ACTION_UP) && slot == -1 && currentHotbarSlot != -1) {
                return;
            } */
            
            if (event == ACTION_DOWN && slot == -1) {
                currentHotbarSlot = -1;
            }
            /*
            if (currentHotbarSlot != -1) {
                return;
            }
            */
            return;
        }

        if (touchEvent == self.primaryTouch) {
            if ([self isTouchInactive:self.primaryTouch]) return; // FIXME: should be? ACTION_UP will never be sent
            if (event == ACTION_MOVE && isGrabbing) {
                event = ACTION_MOVE_MOTION;
                CGPoint prevLocationInView = [touchEvent previousLocationInView:self.rootView];
                locationInView.x -= prevLocationInView.x;
                locationInView.y -= prevLocationInView.y;
            }
            [self sendTouchPoint:locationInView withEvent:event];
        }
    //}
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:YES];
        }
    }
    // Always call super so that inputTextField (UITextInput) can receive
    // key events for text input (e.g., Minecraft chat).
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:NO];
        }
    }
    // Always call super so that inputTextField (UITextInput) can receive
    // key-up events properly.
    [super pressesEnded:presses withEvent:event];
}

- (BOOL)prefersPointerLocked {
    return GCMouse.mice.count > 0 && (isGrabbing || virtualMouseEnabled);
}

- (void)registerMouseCallbacks:(GCMouse *)mouse {
    NSLog(@"Input: Got mouse %@", mouse);
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        // Always forward mouse movement to the game.
        // When pointer is locked (in-game grabbing), deltaX/deltaY are true deltas.
        // When pointer is NOT locked (menu, or Bluetooth mouse before lock activates),
        // we still send the delta so the virtual mouse or cursor can move.
        [self sendTouchPoint:CGPointMake(deltaX, -deltaY) withEvent:ACTION_MOVE_MOTION];
    };

    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed, 0);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed, 0);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed, 0);
    };
    // GLFW can handle up to 8 mouse buttons, the first 3 buttons are reserved for left,middle,right
    for (int i = 0; i < MIN(mouse.mouseInput.auxiliaryButtons.count, 5); i++) {
        mouse.mouseInput.auxiliaryButtons[i].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_4 + i, pressed, 0);
        };
    }

    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        // Workaround MC-121772 (macOS/iOS feature)
        CallbackBridge_nativeSendScroll(value, value);
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        // Workaround MC-121772 (macOS/iOS feature)
        CallbackBridge_nativeSendScroll(-value, -value);
    };

    if (getPrefBool(@"control.hardware_hide")) {
        self.ctrlView.hidden = YES;
    }
}

- (void)surfaceOnClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    
    if (!self.shouldTriggerClick) return;

    if (sender.state == UIGestureRecognizerStateRecognized) {
        if (currentHotbarSlot == -1) {
            if (!self.enableMouseGestures) return;
            CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 1, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                    GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 0, 0);
            });
        } else {
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 1, 0);
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 0, 0);
        }
    }
}

- (void)surfaceOnDoubleClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    
    if (sender.state == UIGestureRecognizerStateRecognized && isGrabbing) {
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        CGPoint point = [sender locationInView:self.rootView];
        int hotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(point.x * screenScale, point.y * screenScale) : -1;
        if (hotbarSlot != -1 && currentHotbarSlot == hotbarSlot) {
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 1, 0);
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 0, 0);
        }
    }
}

- (void)surfaceOnHover:(UIGestureRecognizer *)sender {
    if (isGrabbing) return;
    
    CGPoint point = [sender locationInView:self.rootView];
    // NSLog(@"Mouse move!!");
    // NSLog(@"Mouse pos = %f, %f", point.x, point.y);
    switch (sender.state) {
        case UIGestureRecognizerStateBegan:
            [self sendTouchPoint:point withEvent:ACTION_DOWN];
            break;
        case UIGestureRecognizerStateChanged:
            [self sendTouchPoint:point withEvent:ACTION_MOVE];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            [self sendTouchPoint:point withEvent:ACTION_UP];
            break;
        default:
            // point = CGPointMake(-1, -1);
            break;
    }
}

-(void)surfaceOnLongpress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.mediumHaptic impactOccurred];
        }
    }
    
    if (!self.slideableHotbar) {
        CGPoint location = [sender locationInView:self.rootView];
        CGFloat screenScale = UIScreen.mainScreen.scale;
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(location.x * screenScale, location.y * screenScale) : -1;
    }
    if (sender.state == UIGestureRecognizerStateBegan) {
        self.shouldTriggerClick = NO;
        if (currentHotbarSlot == -1) {

            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 1, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 1, 0);
        }
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        // Nothing to do here, already handled in touchesMoved
    } else if (sender.state == UIGestureRecognizerStateCancelled
        || sender.state == UIGestureRecognizerStateFailed
            || sender.state == UIGestureRecognizerStateEnded)
    {
        if (currentHotbarSlot == -1) {
            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 0, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 0, 0);
        }
    }
}

- (void)surfaceOnTouchesScroll:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    
    if (isGrabbing) return;
    if (sender.state == UIGestureRecognizerStateBegan ||
        sender.state == UIGestureRecognizerStateChanged ||
        sender.state == UIGestureRecognizerStateEnded) {
        CGPoint velocity = [sender velocityInView:self.rootView];
        if (velocity.x != 0.0f || velocity.y != 0.0f) {
            CallbackBridge_nativeSendScroll(velocity.x/self.view.frame.size.width, velocity.y/self.view.frame.size.height);
        }
    }
}

#pragma mark - Input view stuff

-(BOOL)textFieldShouldReturn:(UITextField *)textField {
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 1, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 0, 0);
    textField.text = @" ";
    return YES;
}

#pragma mark - On-screen button functions

- (void)executebtn:(ControlButton *)sender withAction:(int)action {
    int held = action == ACTION_DOWN;
    for (int i = 0; i < 4; i++) {
        int keycode = ((NSNumber *)sender.properties[@"keycodes"][i]).intValue;
        if (keycode < 0) {
            switch (keycode) {
                case SPECIALBTN_KEYBOARD:
                    if (held == 0) {
                        if (self.inputTextField.isFirstResponder) {
                            [self.inputTextField resignFirstResponder];
                            self.inputTextField.alpha = 1.0f;
                        } else {
                            [self.inputTextField becomeFirstResponder];
                            // Insert an undeletable space
                            self.inputTextField.text = @" ";
                        }
                    }
                    break;

                case SPECIALBTN_MOUSEPRI:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, held, 0);
                    break;

                case SPECIALBTN_MOUSESEC:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, held, 0);
                    break;

                case SPECIALBTN_MOUSEMID:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, held, 0);
                    break;

                case SPECIALBTN_TOGGLECTRL:
                    [self executebtn_special_togglebtn:held];
                    break;

                case SPECIALBTN_SCROLLDOWN:
                    if (!held) {
                        CallbackBridge_nativeSendScroll(0.0, 1.0);
                    }
                    break;

                case SPECIALBTN_SCROLLUP:
                    if (!held) {
                        CallbackBridge_nativeSendScroll(0.0, -1.0);
                    }
                    break;

                case SPECIALBTN_VIRTUALMOUSE:
                    if (!isGrabbing && !held) {
                        virtualMouseEnabled = !virtualMouseEnabled;
                        self.mousePointerView.hidden = !virtualMouseEnabled;
                        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
                        [self setNeedsUpdateOfPrefersPointerLocked];
                    }
                    break;

                case SPECIALBTN_MENU:
                    if (!held) {
                        [self actionOpenNavigationMenu];
                    }
                    break;

                default:
                    NSLog(@"Warning: button %@ sent unknown special keycode: %d", sender.titleLabel.text, keycode);
                    break;
            }
        } else if (keycode > 0) {
            // there's no key id 0, but we accidentally used -1 as a special key id, so we had to do that
            // if (keycode == 0) { keycode = -1; }
            // at the moment, send unknown keycode does nothing, may even cause performance issue, so ignore it
            CallbackBridge_nativeSendKey(keycode, 0, held, 0);
        }
    }
}

- (void)executebtn_down:(ControlButton *)sender
{
    if(self.shouldTriggerHaptic) {
        [self.lightHaptic impactOccurred];
    }
    
    if (sender.savedBackgroundColor == nil) {
        [self executebtn:sender withAction:ACTION_DOWN];
    }
    if ([self.swipeableButtons containsObject:sender]) {
        self.swipingButton = sender;
    }
}

- (void)executebtn_swipe:(UIPanGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateCancelled || sender.state == UIGestureRecognizerStateEnded) {
        [self executebtn_up:self.swipingButton isOutside:NO];
        return;
    }
    CGPoint location = [sender locationInView:self.ctrlView];
    for (ControlButton *button in self.swipeableButtons) {
        if (CGRectContainsPoint(button.frame, location) && (ControlButton *)self.swipingButton != button) {
            [self executebtn_up:self.swipingButton isOutside:NO];
            self.swipingButton = (ControlButton *)button;
            [self executebtn:self.swipingButton withAction:ACTION_DOWN];
            break;
        }
    }
}

- (void)executebtn_up:(ControlButton *)sender isOutside:(BOOL)isOutside
{
    if (self.swipingButton == sender) {
        [self executebtn:self.swipingButton withAction:ACTION_UP];
        self.swipingButton = nil;
    } else if (sender.savedBackgroundColor == nil) {
        [self executebtn:sender withAction:ACTION_UP];
        return;
    }

    if (isOutside || sender.savedBackgroundColor == nil) {
        return;
    }

    sender.isToggleOn = !sender.isToggleOn;
    if (sender.isToggleOn) {
        sender.backgroundColor = [self.view.tintColor colorWithAlphaComponent:CGColorGetAlpha(sender.savedBackgroundColor.CGColor)];
        [self executebtn:sender withAction:ACTION_DOWN];
    } else {
        sender.backgroundColor = sender.savedBackgroundColor;
        [self executebtn:sender withAction:ACTION_UP];
    }

    if(self.shouldTriggerHaptic) {
        [self.lightHaptic impactOccurred];
    }
}

- (void)executebtn_up_inside:(ControlButton *)sender {
    [self executebtn_up:sender isOutside:NO];
}

- (void)executebtn_up_outside:(ControlButton *)sender {
    [self executebtn_up:sender isOutside:YES];
}

- (void)executebtn_special_togglebtn:(int)held {
    if (held) return;
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

#pragma mark - Input: On-screen touch events

int touchesMovedCount;
// Equals to Android ACTION_DOWN
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesBegan:touches withEvent:event];
    int i = 0;
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            continue; // handle this in a different place
        }
        CGPoint locationInView = [touch locationInView:self.rootView];
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if ([self isTouchInactive:self.hotbarTouch] && currentHotbarSlot != -1) {
            self.hotbarTouch = touch;
        }
        if ([self isTouchInactive:self.primaryTouch] && currentHotbarSlot == -1) {
            self.primaryTouch = touch;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
        break;
    }
}

// Equals to Android ACTION_MOVE
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesMoved:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            if (!isGrabbing && !virtualMouseEnabled) {
                CGPoint point = [touch locationInView:self.rootView];
                [self sendTouchPoint:point withEvent:ACTION_MOVE];
            }
            continue; // handle this in a different place
        }
        if (self.hotbarTouch != touch && [self isTouchInactive:self.primaryTouch]) {
            // Replace the inactive touch with the current active touch
            self.primaryTouch = touch;
            [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_MOVE];
    }
}

// For ACTION_UP and ACTION_CANCEL
- (void)touchesEndedGlobal:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            continue; // handle this in a different place
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_UP];
    }
}

// Equals to Android ACTION_UP
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesEnded:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

// Equals to Android ACTION_CANCEL
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesCancelled:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

+ (BOOL)isRunning {
    return [UIWindow.mainWindow.rootViewController isKindOfClass:SurfaceViewController.class];
}

+ (GameSurfaceView *)surface {
    return pojavWindow;
}

@end
