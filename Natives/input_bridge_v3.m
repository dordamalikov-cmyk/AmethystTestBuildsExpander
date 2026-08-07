/*
 * V3 input bridge implementation.
 *
 * Status:
 * - Active development
 * - Works with some bugs:
 *  + Modded versions gives broken stuff..
 */

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "SurfaceViewController.h"

#include <assert.h>
#include <dlfcn.h>
#include <libgen.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "jni.h"
#include "glfw_keycodes.h"
#include "ios_uikit_bridge.h"
#include "utils.h"

#include "JavaLauncher.h"

jint (*orig_ProcessImpl_forkAndExec)(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream);
jlong (*orig_ProcessHandleImpl_isAlive0)(JNIEnv *env, jclass clazz, jlong jpid);

NSString* processPath(NSString* path) {
    if ([path hasPrefix:@"file:"]) {
        path = [path substringFromIndex:5].stringByRemovingPercentEncoding;
    }
    path = path.stringByResolvingSymlinksInPath;

    NSString *prefix = @"file";
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"shareddocuments://"]] &&
      ![path hasPrefix:@"/var/mobile/Documents"]) {
        // Prefer opening in Files if containerized
        prefix = @"shareddocuments";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"filza://"]]) {
        // Open in Filza if installed
        prefix = @"filza";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"santander://"]]) {
        // Open in Santander if installed
        prefix = @"santander";
    }

    return [NSString stringWithFormat:@"%@://%@", prefix, path];
}

void openURLGlobal(NSString *path) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([path hasPrefix:@"http"]) {
            openLink(UIWindow.mainWindow.rootViewController, [NSURL URLWithString:path]);
            dispatch_group_leave(group);
            return;
        }
        NSString *realPath = processPath(path);
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:realPath] options:@{} completionHandler:^(BOOL success) {
            if (success) {
                NSLog(@"Opened \"%@\"", realPath);
            } else {
                NSLog(@"Failed to open \"%@\"", realPath);
            }
            dispatch_group_leave(group);
        }];
    });

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

/**
 * Hooked version of java.lang.UNIXProcess.forkAndExec()
 * which is used to handle the "open" command.
 */
jint
hooked_ProcessImpl_forkAndExec(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream) {
    char *pProg = (char *)((*env)->GetByteArrayElements(env, prog, NULL));

    // Here we only handle the "open" command
    if (strcmp(basename(pProg), "open")) {
        (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
        return orig_ProcessImpl_forkAndExec(env, process, mode, helperpath, prog, argBlock, argc, envBlock, envc, dir, std_fds, redirectErrorStream);
    }

    char *path = (char *)((*env)->GetByteArrayElements(env, argBlock, NULL));
    openURLGlobal(@(path));

    (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
    (*env)->ReleaseByteArrayElements(env, argBlock, (jbyte *)path, 0);
    return 0;
}

/**
 * Hooked version of java.lang.ProcessHandleImpl.isAlive0()
 * which is used to ignore "Operation not permitted"
 */
jlong hooked_ProcessHandleImpl_isAlive0(JNIEnv *env, jclass clazz, jlong jpid) {
    jlong result = orig_ProcessHandleImpl_isAlive0(env, clazz, jpid);
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
    }
    return result;
}

// Part of awt_bridge
void CTCClipboard_nQuerySystemClipboard(JNIEnv *env, jclass clazz) {
    if(method_SystemClipboardDataReceived == NULL) {
        class_CTCClipboard = (*env)->NewGlobalRef(env, clazz);
        method_SystemClipboardDataReceived = (*env)->GetStaticMethodID(env, clazz, "systemClipboardDataReceived", "(Ljava/lang/String;Ljava/lang/String;)V");
    }
    // From Java_net_kdt_pojavlaunch_AWTInputBridge_nativeClipboardReceived
    // Note: we cannot use main_queue here as it will cause deadlock
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        JNIEnv *env;
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &env, NULL);
        const char* mimeChars = "text/plain";
        (*env)->CallStaticVoidMethod(env, class_CTCClipboard, method_SystemClipboardDataReceived,
            UIKit_accessClipboard(env, CLIPBOARD_PASTE, NULL),
            (*env)->NewStringUTF(env, mimeChars));
        (*runtimeJavaVMPtr)->DetachCurrentThread(runtimeJavaVMPtr);
    });
}

void CTCClipboard_nPutClipboardData(JNIEnv* env, jclass clazz, jstring clipboardData, jstring clipboardDataMime) {
    // TODO: handle non-text data(?)
    UIKit_accessClipboard(env, CLIPBOARD_COPY, clipboardData);
}

void CTCDesktopPeer_openGlobal(JNIEnv *env, jclass clazz, jstring path) {
    const char* stringChars = (*env)->GetStringUTFChars(env, path, NULL);
    openURLGlobal(@(stringChars));
    (*env)->ReleaseStringUTFChars(env, path, stringChars);
}

void hackFix18LWJGL(void *addr) {
    addr = (void *)((uintptr_t)addr & ~PAGE_MASK);
    if(DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED)) return;
    if(!mprotect(addr, PAGE_SIZE, PROT_READ | PROT_EXEC)) return;
    // FIXME: For some reason the one page in liblwjgl.dylib is mapped as r-x/rwx (COW), and recent builds on iOS 18 switches it to r--/rw- causing codesign failure. Here we hack it to map anon page to get r-x back
    char tempPage[PAGE_SIZE];
    memcpy(tempPage, addr, PAGE_SIZE);
    void *result = mmap(addr, PAGE_SIZE, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    if (result == MAP_FAILED) {
        NSLog(@"hackFix18LWJGL: mmap failed: %s", strerror(errno));
        return;
    }
    memcpy(addr, tempPage, PAGE_SIZE);
    mprotect(addr, PAGE_SIZE, PROT_READ | PROT_EXEC);
}

void registerOpenHandler(JNIEnv *env) {
    jclass cls;

    // Hook forkAndExec
    orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_UNIXProcess_forkAndExec");
    if (!orig_ProcessImpl_forkAndExec) {
        orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessImpl_forkAndExec");
        cls = (*env)->FindClass(env, "java/lang/ProcessImpl");
    } else {
        cls = (*env)->FindClass(env, "java/lang/UNIXProcess");
    }
    JNINativeMethod forkAndExecMethod[] = {
        {"forkAndExec", "(I[B[B[BI[BI[B[IZ)I", (void *)&hooked_ProcessImpl_forkAndExec}
    };
    (*env)->RegisterNatives(env, cls, forkAndExecMethod, 1);

    // (Java 17 only) Hook isAlive0
    cls = (*env)->FindClass(env, "java/lang/ProcessHandleImpl");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 8
        (*env)->ExceptionClear(env);
    } else {
        orig_ProcessHandleImpl_isAlive0 = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessHandleImpl_isAlive0");
        JNINativeMethod isAlive0Method[] = {
            {"isAlive0", "(J)J", (void *)&hooked_ProcessHandleImpl_isAlive0}
        };
        (*env)->RegisterNatives(env, cls, isAlive0Method, 1);
    }

    // Register CTCClipboard natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCClipboard");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17
        (*env)->ExceptionClear(env);
        cls = (*env)->FindClass(env, "com/github/caciocavallosilano/cacio/ctc/CTCClipboard");
    }
    JNINativeMethod clipboardMethods[] = {
        {"nQuerySystemClipboard", "()V", (void *)&CTCClipboard_nQuerySystemClipboard},
        {"nPutClipboardData", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)&CTCClipboard_nPutClipboardData}
    };
    (*env)->RegisterNatives(env, cls, clipboardMethods, 2);

    // Register CTCDesktopPeer natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCDesktopPeer");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17, not available
        //(*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return;
    }
    JNINativeMethod peerOpenMethods[] = {
        {"openFile", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal},
        {"openUri", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal}
    };
    (*env)->RegisterNatives(env, cls, peerOpenMethods, 2);
}

// JNI_OnLoad
void JNI_OnLoadGLFW() {
    if (runtimeJNIEnvPtr == NULL) {
        NSLog(@"[JNI] JNI_OnLoadGLFW: runtimeJNIEnvPtr is NULL, skipping");
        return;
    }
    jclass clazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    if (clazz == NULL) {
        if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
            (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        }
        NSLog(@"[JNI] JNI_OnLoadGLFW: FindClass(org/lwjgl/glfw/GLFW) returned NULL, skipping registration");
        return;
    }
    vmGlfwClass = (*runtimeJNIEnvPtr)->NewGlobalRef(runtimeJNIEnvPtr, clazz);
    method_internalWindowSizeChanged = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, vmGlfwClass, "internalWindowSizeChanged", "(JII)V");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        method_internalWindowSizeChanged = NULL;
    }
    jfieldID field_keyDownBuffer = (*runtimeJNIEnvPtr)->GetStaticFieldID(runtimeJNIEnvPtr, vmGlfwClass, "keyDownBuffer", "Ljava/nio/ByteBuffer;");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        field_keyDownBuffer = NULL;
    }
    if (field_keyDownBuffer != NULL) {
        jobject keyDownBufferJ = (*runtimeJNIEnvPtr)->GetStaticObjectField(runtimeJNIEnvPtr, vmGlfwClass, field_keyDownBuffer);
        if (keyDownBufferJ != NULL) {
            keyDownBuffer = (*runtimeJNIEnvPtr)->GetDirectBufferAddress(runtimeJNIEnvPtr, keyDownBufferJ);
        }
    }
    NSLog(@"[JNI] JNI_OnLoadGLFW registered, class=%p, method=%p, keyDownBuffer=%p", (void *)vmGlfwClass, (void *)method_internalWindowSizeChanged, (void *)keyDownBuffer);
}

jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    runtimeJavaVMPtr = vm;

    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    registerOpenHandler(env);
    if (!getenv("POJAV_SKIP_JNI_GLFW")) {
        runtimeJNIEnvPtr = env;
        JNI_OnLoadGLFW();
    }

    return JNI_VERSION_1_4;
}

// Should be?
void JNI_OnUnload(JavaVM* vm, void* reserved) {
    runtimeJNIEnvPtr = NULL;
}

#define ADD_CALLBACK_WWIN(NAME) \
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(JNIEnv * env, jclass cls, jlong window, jlong callbackptr) { \
    void** oldCallback = (void**) &GLFW_invoke_##NAME; \
    GLFW_invoke_##NAME = (GLFW_invoke_##NAME##_func*) (uintptr_t) callbackptr; \
    return (jlong) (uintptr_t) *oldCallback; \
}

ADD_CALLBACK_WWIN(Char)
ADD_CALLBACK_WWIN(CharMods)
ADD_CALLBACK_WWIN(CursorEnter)
ADD_CALLBACK_WWIN(CursorPos)
ADD_CALLBACK_WWIN(FramebufferSize)
ADD_CALLBACK_WWIN(Key)
ADD_CALLBACK_WWIN(MouseButton)
ADD_CALLBACK_WWIN(Scroll)
ADD_CALLBACK_WWIN(WindowPos)
ADD_CALLBACK_WWIN(WindowSize)

#undef ADD_CALLBACK_WWIN

void handleFramebufferSizeJava(void* window, int w, int h) {
    if(GLFW_invoke_CursorEnter)GLFW_invoke_CursorEnter(window, 1);
    if(GLFW_invoke_WindowPos)GLFW_invoke_WindowPos(window, 0, 0);
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, vmGlfwClass, method_internalWindowSizeChanged, (long)window, w, h);
}

void pojavPumpEvents(void* window) {
    static BOOL setInputReady = NO;
    if(!setInputReady) {
        setInputReady = YES;
        CallbackBridge_nativeSetInputReady(YES);
    }
    //__android_log_print(ANDROID_LOG_INFO, "input_bridge_v3", "pojavPumpevents %d", eventCounter);
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if((cLastX != cursorX || cLastY != cursorY) && GLFW_invoke_CursorPos) {
        cLastX = cursorX;
        cLastY = cursorY;
        if (isUseStackQueueCall)
            GLFW_invoke_CursorPos(window, cursorX, cursorY);
    }
    for(size_t i = 0; i < counter; i++) {
        GLFWInputEvent event = events[i];
        switch(event.type) {
            case EVENT_TYPE_CHAR:
                // NSLog(@"[KeyboardDebug] Queue: Processing EVENT_TYPE_CHAR for character %d", event.i1);
                if(GLFW_invoke_Char) GLFW_invoke_Char(window, event.i1);
                break;
            case EVENT_TYPE_CHAR_MODS:
                // NSLog(@"[KeyboardDebug] Queue: Processing EVENT_TYPE_CHAR_MODS for character %d", event.i1);
                if(GLFW_invoke_CharMods) {
                    GLFW_invoke_CharMods(window, event.i1, event.i2);
                } else if (GLFW_invoke_Char) {
                    //NSLog(@"[KeyboardDebug] Queue: Fallback to GLFW_invoke_Char for character %d", event.i1);
                    GLFW_invoke_Char(window, event.i1);
                }
                break;
            case EVENT_TYPE_KEY:
                if(GLFW_invoke_Key) GLFW_invoke_Key(window, event.i1, event.i2, event.i3, event.i4);
                break;
            case EVENT_TYPE_MOUSE_BUTTON:
                if(GLFW_invoke_MouseButton) GLFW_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;
            case EVENT_TYPE_SCROLL:
                if(GLFW_invoke_Scroll) GLFW_invoke_Scroll(window, event.f1, event.f2);
                break;
            case EVENT_TYPE_FRAMEBUFFER_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_FramebufferSize) GLFW_invoke_FramebufferSize(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_WINDOW_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_WindowSize) GLFW_invoke_WindowSize(window, event.i1, event.i2);
                break;
        }
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}
void pojavRewindEvents() {
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(JNIEnv *env, jclass clazz, jlong window, jobject xpos,
                                          jobject ypos) {
    *(double*)(*env)->GetDirectBufferAddress(env, xpos) = cursorX;
    *(double*)(*env)->GetDirectBufferAddress(env, ypos) = cursorY;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(JNIEnv *env, jclass clazz, jlong window,
                                            jdoubleArray xpos, jdoubleArray ypos) {
    (*env)->SetDoubleArrayRegion(env, xpos, 0,1, &cursorX);
    (*env)->SetDoubleArrayRegion(env, ypos, 0,1, &cursorY);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(JNIEnv *env, jclass clazz, jlong window, jdouble xpos,
                                          jdouble ypos) {
    cLastX = cursorX = xpos;
    cLastY = cursorY = ypos;
}

void sendData(short type, int i1, int i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->i1 = i1;
        event->i2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void sendDataFloat(short type, float i1, float i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->f1 = i1;
        event->f2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void closeGLFWWindow() {
    NSLog(@"Closing GLFW window");

    /*
    jclass glfwClazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    assert(glfwClazz != NULL);
    jmethodID glfwMethod = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, glfwMethod, "glfwSetWindowShouldClose", "(JZ)V");
    assert(glfwMethod != NULL);
    
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        glfwClazz, glfwMethod,
        (jlong) showingWindow, JNI_TRUE
    );
    */
    exit(-1);
}

const int hotbarKeys[9] = {
    GLFW_KEY_1, GLFW_KEY_2, GLFW_KEY_3,
    GLFW_KEY_4, GLFW_KEY_5, GLFW_KEY_6,
    GLFW_KEY_7, GLFW_KEY_8, GLFW_KEY_9
};
int guiScale = 1;
int mcscale(CGFloat input) {
    return (int)((guiScale * input)/resolutionScale);
}
int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y) {
    if (isGrabbing == JNI_FALSE) {
        return -1;
    }

    int barHeight = mcscale(20);
    int barY = physicalHeight - barHeight;
    if (y < barY) return -1;

    int barWidth = mcscale(180);
    int barX = (physicalWidth / 2) - (barWidth / 2);
    if (x < barX || x >= barX + barWidth) return -1;

    return hotbarKeys[(int) MathUtils_map(x, barX, barX + barWidth, 0, 9)];
}

JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_updateMCGuiScale(JNIEnv* env, jclass clazz, jint scale) {
    guiScale = scale;
}

JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(JNIEnv* env, jclass clazz, jint action, jstring copySrc) {
    NSDebugLog(@"Debug: Clipboard access is going on\n");
    return UIKit_accessClipboard(env, action, copySrc);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(JNIEnv* env, jclass clazz, jboolean grabbing, jfloat xset, jfloat yset) {
    isGrabbing = grabbing;

    dispatch_async(dispatch_get_main_queue(), ^{
        SurfaceViewController *vc = ((SurfaceViewController *)UIWindow.mainWindow.rootViewController);
        [vc updateGrabState];
    });
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeIsGrabbing(JNIEnv* env, jclass clazz) {
    return isGrabbing;
}

void CallbackBridge_nativeSetInputReady(BOOL inputReady) {
    isInputReady = inputReady;
    if (inputReady) {
        if (GLFW_invoke_FramebufferSize) {
            hackFix18LWJGL(GLFW_invoke_FramebufferSize);
            GLFW_invoke_FramebufferSize((void*) showingWindow, windowWidth, windowHeight);
        }
        if (GLFW_invoke_WindowSize) {
            GLFW_invoke_FramebufferSize((void*) showingWindow, windowWidth, windowHeight);
        }
    }
}

// SDL key/text injection (defined below, near CallbackBridge_nativeSendKey).
static void sdlInjectKey(int key, int action, int mods);
static void sdlInjectChar(jchar codepoint);

BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */) {
    if (g_sdlInputActive) {
        sdlInjectChar(codepoint);
        return YES;
    }
    if (GLFW_invoke_Char && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_CHAR, codepoint, 0, 0, 0);
        } else {
            GLFW_invoke_Char((void*) showingWindow, (unsigned int) codepoint);
            // return lwjgl2_triggerCharEvent(codepoint);
        }
        return YES;
    }
    return NO;
}

BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods) {
    // NSLog(@"[KeyboardDebug] Bridge: Got character code=%d, modifiers=%d", codepoint, mods);
    // NSLog(@"[KeyboardDebug] Bridge: Game status: GLFW_invoke_CharMods=%p, GLFW_invoke_Char=%p, isInputReady=%d",
    //      GLFW_invoke_CharMods, GLFW_invoke_Char, isInputReady);

    if (g_sdlInputActive) {
        sdlInjectChar(codepoint);   // chars only; mods already tracked per-key
        return YES;
    }

    if ((GLFW_invoke_CharMods || GLFW_invoke_Char) && isInputReady) {
        if (isUseStackQueueCall) {
            // NSLog(@"[KeyboardDebug] Bridge: Sending character %d to stack-queue (isUseStackQueueCall)", codepoint);
            sendData(EVENT_TYPE_CHAR_MODS, (unsigned int) codepoint, mods, 0, 0);
        } else {
            if (GLFW_invoke_CharMods) {
                // NSLog(@"[KeyboardDebug] Bridge: Direct call to GLFW_invoke_CharMods for character %d", codepoint);
                GLFW_invoke_CharMods((void*) showingWindow, codepoint, mods);
            } else {
                // NSLog(@"[KeyboardDebug] Bridge: Fallback! Direct call to GLFW_invoke_Char for character %d", codepoint);
                GLFW_invoke_Char((void*) showingWindow, (unsigned int) codepoint);
            }
        }
        return YES;
    }
    
    // NSLog(@"[KeyboardDebug] Bridge CRITICAL ERROR: Character %d DISCARDED! Reason: No handlers or game not ready.", codepoint);
    return NO;
}
/*
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorEnter(JNIEnv* env, jclass clazz, jint entered) {
    if (GLFW_invoke_CursorEnter && isInputReady) {
        GLFW_invoke_CursorEnter(showingWindow, entered);
    }
}
*/
void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y) {
    if (!GLFW_invoke_CursorPos || !isInputReady) return;

    switch (event) {
        case ACTION_DOWN:
        case ACTION_UP:
            if (!isGrabbing) {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE:
            if (isGrabbing) {
                cursorX += x - cLastX;
                cursorY += y - cLastY;
            } else {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE_MOTION:
            cursorX += x;
            cursorY += y;
            break;
    }

    if (!isUseStackQueueCall) {
        GLFW_invoke_CursorPos((void*) showingWindow, (double) cursorX, (double) cursorY);
    }
}

char getKeyModifiers(int key, int action) {
    static char currMods;
    char mod;
    switch (key) {
        case GLFW_KEY_LEFT_SHIFT:
            mod = GLFW_MOD_SHIFT;
            break;
        case GLFW_KEY_LEFT_CONTROL:
            mod = GLFW_MOD_CONTROL;
            break;
        case GLFW_KEY_LEFT_ALT:
            mod = GLFW_MOD_ALT;
            break;
        case GLFW_KEY_CAPS_LOCK:
            mod = GLFW_MOD_CAPS_LOCK;
            break;
        case GLFW_KEY_NUM_LOCK:
            mod = GLFW_MOD_NUM_LOCK;
            break;
        default:
            return currMods;
    }
    if (action) {
        currMods |= mod;
    } else {
        currMods &= ~mod;
    }
    return currMods;
}

// ============================================================================
// SDL3 key/text injection (MC 26.3+, LWJGL 3.4.1 / org.lwjgl.sdl).
//
// MC 26.3 reads input from SDL events; the GLFW CallbackBridge path
// (GLFW_invoke_*) is dead for it. g_sdlInputActive (set by SurfaceViewController
// once the SDL window appears) routes keys/characters to SDL here.
//
// The internal SDL_SendKeyboardKey/SDL_SendKeyboardText symbols are NOT exported
// from the bundled libSDL3.dylib, so we inject through the public SDL_PushEvent:
// SDL_Event is a 128-byte union that SDL_PushEvent copies, so we hand it a
// full-size zeroed mirror and populate only the fields we need. For text events
// SDL duplicates the string on push (see SDL_SendKeyboardText's own strdup/push/
// free pattern), so the caller frees its copy right after the call.
// ============================================================================

typedef int      (*SDL3_PushEventFn)(void *event);                       // int SDL_PushEvent(SDL_Event *)
typedef uint32_t (*SDL3_GetKeyFromScancodeFn)(int scancode);            // SDL_Keycode SDL_GetKeyFromScancode(SDL_Scancode)

enum {
    SDL3_EVENT_KEY_DOWN   = 0x300,
    SDL3_EVENT_KEY_UP     = 0x301,
    SDL3_EVENT_TEXT_INPUT = 0x303,
};

// Mirrors SDL_KeyboardEvent (SDL_events.h, SDL 3.4.0) — field order matters.
typedef struct SDL3_KeyboardEvent {
    uint32_t type;      // SDL_EVENT_KEY_DOWN / SDL_EVENT_KEY_UP
    uint32_t reserved;
    uint64_t timestamp; // 0 -> SDL fills
    uint32_t which;     // SDL_KeyboardID (0 = global)
    uint32_t mod;       // SDL_Keymod
    uint32_t key;       // SDL_Keycode
    int      scancode;  // SDL_Scancode
    bool     down;
    bool     repeat;
    uint32_t raw;
} SDL3_KeyboardEvent;

// Mirrors SDL_TextInputEvent (SDL_events.h, SDL 3.4.0).
typedef struct SDL3_TextInputEvent {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    char    *text;      // UTF-8, duplicated by SDL on push
} SDL3_TextInputEvent;

// SDL_Event is 128 bytes on 64-bit; SDL_PushEvent copies that much out of the
// pointer we give it, so the buffer must be full-size (never a bare struct).
typedef union SDL3_EventMirror {
    char                buf[128];
    SDL3_KeyboardEvent  key;
    SDL3_TextInputEvent text;
} SDL3_EventMirror;

static void                    *g_sdlKeyLib = NULL;
static SDL3_PushEventFn         g_sdlKeyPushEvent = NULL;
static SDL3_GetKeyFromScancodeFn g_sdlKeyGetFromScancode = NULL;

static void sdlKeyLoad(void) {
    if (g_sdlKeyPushEvent) return;
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath
                      stringByAppendingPathComponent:@"libSDL3.dylib"];
    g_sdlKeyLib = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!g_sdlKeyLib) {
        fprintf(stderr, "[SDLKey] dlopen %s failed: %s\n", path.UTF8String, dlerror());
        fflush(stderr);
        return;
    }
    g_sdlKeyPushEvent = (SDL3_PushEventFn)dlsym(g_sdlKeyLib, "SDL_PushEvent");
    g_sdlKeyGetFromScancode = (SDL3_GetKeyFromScancodeFn)dlsym(g_sdlKeyLib, "SDL_GetKeyFromScancode");
    if (!g_sdlKeyPushEvent) {
        fprintf(stderr, "[SDLKey] dlsym(SDL_PushEvent) failed\n");
    }
    fflush(stderr);
}

// GLFW key -> SDL3 scancode (SDL3 scancodes == USB HID usage ids). -1 = unknown.
static int sdlGlfwToScancode(int key) {
    if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) return 4 + (key - GLFW_KEY_A);          // 65-90 -> 4-29
    if (key >= GLFW_KEY_0 && key <= GLFW_KEY_9) {                                       // 48-57 -> 39,30..38
        static const int sdig[10] = {39,30,31,32,33,34,35,36,37,38};
        return sdig[key - GLFW_KEY_0];
    }
    if (key >= GLFW_KEY_F1 && key <= GLFW_KEY_F12) return 58 + (key - GLFW_KEY_F1);     // 290-301 -> 58-69
    switch (key) {
        case GLFW_KEY_SPACE:        return 44;   // SDL_SCANCODE_SPACE
        case GLFW_KEY_APOSTROPHE:   return 52;   // SDL_SCANCODE_APOSTROPHE
        case GLFW_KEY_COMMA:        return 54;   // SDL_SCANCODE_COMMA
        case GLFW_KEY_MINUS:        return 45;   // SDL_SCANCODE_MINUS
        case GLFW_KEY_PERIOD:       return 55;   // SDL_SCANCODE_PERIOD
        case GLFW_KEY_SLASH:        return 56;   // SDL_SCANCODE_SLASH
        case GLFW_KEY_SEMICOLON:    return 51;   // SDL_SCANCODE_SEMICOLON
        case GLFW_KEY_EQUAL:        return 46;   // SDL_SCANCODE_EQUALS
        case GLFW_KEY_LEFT_BRACKET: return 47;   // SDL_SCANCODE_LEFTBRACKET
        case GLFW_KEY_BACKSLASH:    return 49;   // SDL_SCANCODE_BACKSLASH
        case GLFW_KEY_RIGHT_BRACKET:return 48;   // SDL_SCANCODE_RIGHTBRACKET
        case GLFW_KEY_GRAVE_ACCENT: return 53;   // SDL_SCANCODE_GRAVE
        case GLFW_KEY_ESCAPE:       return 41;   // SDL_SCANCODE_ESCAPE
        case GLFW_KEY_ENTER:        return 40;   // SDL_SCANCODE_RETURN
        case GLFW_KEY_TAB:          return 43;   // SDL_SCANCODE_TAB
        case GLFW_KEY_BACKSPACE:    return 42;   // SDL_SCANCODE_BACKSPACE
        case GLFW_KEY_INSERT:       return 73;   // SDL_SCANCODE_INSERT
        case GLFW_KEY_DELETE:       return 76;   // SDL_SCANCODE_DELETE
        case GLFW_KEY_HOME:         return 74;   // SDL_SCANCODE_HOME
        case GLFW_KEY_END:          return 77;   // SDL_SCANCODE_END
        case GLFW_KEY_PAGE_UP:      return 75;   // SDL_SCANCODE_PAGEUP
        case GLFW_KEY_PAGE_DOWN:    return 78;   // SDL_SCANCODE_PAGEDOWN
        case GLFW_KEY_DPAD_UP:      return 82;   // SDL_SCANCODE_UP
        case GLFW_KEY_DPAD_DOWN:    return 81;   // SDL_SCANCODE_DOWN
        case GLFW_KEY_DPAD_LEFT:    return 80;   // SDL_SCANCODE_LEFT
        case GLFW_KEY_DPAD_RIGHT:   return 79;   // SDL_SCANCODE_RIGHT
        case GLFW_KEY_CAPS_LOCK:    return 57;   // SDL_SCANCODE_CAPSLOCK
        case GLFW_KEY_SCROLL_LOCK:  return 71;   // SDL_SCANCODE_SCROLLLOCK
        case GLFW_KEY_NUM_LOCK:     return 83;   // SDL_SCANCODE_NUMLOCKCLEAR
        case GLFW_KEY_LEFT_SHIFT:   return 225;  // SDL_SCANCODE_LSHIFT
        case GLFW_KEY_LEFT_CONTROL: return 224;  // SDL_SCANCODE_LCTRL
        case GLFW_KEY_LEFT_ALT:     return 226;  // SDL_SCANCODE_LALT
        case GLFW_KEY_LEFT_SUPER:   return 227;  // SDL_SCANCODE_LGUI
        case GLFW_KEY_RIGHT_SHIFT:  return 229;  // SDL_SCANCODE_RSHIFT
        case GLFW_KEY_RIGHT_CONTROL:return 228;  // SDL_SCANCODE_RCTRL
        case GLFW_KEY_RIGHT_ALT:    return 230;  // SDL_SCANCODE_RALT
        case GLFW_KEY_RIGHT_SUPER:  return 231;  // SDL_SCANCODE_RGUI
        default: return -1;
    }
}

// GLFW mods -> SDL_Keymod (SDL3: KMOD_SHIFT=0x0003, KMOD_CTRL=0x00C0, KMOD_ALT=0x0300,
// KMOD_GUI=0x0C00, KMOD_CAPS=0x2000, KMOD_NUM=0x4000).
static uint32_t sdlModsFromGLFW(int mods) {
    uint32_t m = 0;
    if (mods & GLFW_MOD_SHIFT)    m |= 0x0003;
    if (mods & GLFW_MOD_CONTROL)  m |= 0x00C0;
    if (mods & GLFW_MOD_ALT)      m |= 0x0300;
    if (mods & GLFW_MOD_SUPER)    m |= 0x0C00;
    if (mods & GLFW_MOD_CAPS_LOCK)m |= 0x2000;
    if (mods & GLFW_MOD_NUM_LOCK) m |= 0x4000;
    return m;
}

static void sdlInjectKey(int key, int action, int mods) {
    if (!g_sdlKeyPushEvent) sdlKeyLoad();
    if (!g_sdlKeyPushEvent) return;
    int sc = sdlGlfwToScancode(key);
    if (sc < 0) {
        fprintf(stderr, "[SDLKey] unmapped GLFW key %d\n", key);
        fflush(stderr);
        return;
    }
    SDL3_EventMirror ev;
    memset(&ev, 0, sizeof(ev));
    ev.key.type      = (action != 0) ? SDL3_EVENT_KEY_DOWN : SDL3_EVENT_KEY_UP;
    ev.key.which     = 0;                                   // SDL_GLOBAL_KEYBOARD_ID
    ev.key.mod       = sdlModsFromGLFW(mods);
    ev.key.key       = g_sdlKeyGetFromScancode ? g_sdlKeyGetFromScancode(sc) : 0;
    ev.key.scancode  = sc;
    ev.key.down      = (action != 0);
    ev.key.repeat    = false;
    g_sdlKeyPushEvent(&ev);
}

static void sdlInjectChar(jchar codepoint) {
    if (!g_sdlKeyPushEvent) sdlKeyLoad();
    if (!g_sdlKeyPushEvent) return;
    unsigned int c = (unsigned int)codepoint;
    char utf8[4];
    size_t n = 0;
    if (c < 0x80) {
        utf8[n++] = (char)c;
    } else if (c < 0x800) {
        utf8[n++] = (char)(0xC0 | (c >> 6));
        utf8[n++] = (char)(0x80 | (c & 0x3F));
    } else {
        utf8[n++] = (char)(0xE0 | (c >> 12));
        utf8[n++] = (char)(0x80 | ((c >> 6) & 0x3F));
        utf8[n++] = (char)(0x80 | (c & 0x3F));
    }
    utf8[n] = '\0';
    char *copy = malloc(n + 1);       // SDL duplicates text on push, so we free ours
    memcpy(copy, utf8, n + 1);
    SDL3_EventMirror ev;
    memset(&ev, 0, sizeof(ev));
    ev.text.type     = SDL3_EVENT_TEXT_INPUT;
    ev.text.windowID = 0;
    ev.text.text     = copy;
    g_sdlKeyPushEvent(&ev);
    free(copy);
}

void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {
    if (g_sdlInputActive) {
        sdlInjectKey(key, action, mods);   // action: 1 = down, 0 = up
        return;                            // SDL mode: no GLFW shim, no Cmd emulation
    }
    if (GLFW_invoke_Key && isInputReady) {
        keyDownBuffer[MAX(0, key-31)]=(jbyte)action;
        if (mods == 0) {
            mods = getKeyModifiers(key, action);
        }

        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_KEY, key, scancode, action, mods);
        } else {
            GLFW_invoke_Key((void*) showingWindow, key, scancode, action, mods);
        }
    }

    // On macOS, Minecraft expects the Command key
    if (key == GLFW_KEY_LEFT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SUPER, 0, action, mods);
    } else if (key == GLFW_KEY_RIGHT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_RIGHT_SUPER, 0, action, mods);
    }
}

void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {
    if (isInputReady) {
        if (button == -1) {
        } else if (GLFW_invoke_MouseButton) {
            if (mods == 0) {
                mods = getKeyModifiers(0, action);
            }

            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_MOUSE_BUTTON, button, action, mods, 0);
            } else {
                GLFW_invoke_MouseButton((void*) showingWindow, button, action, mods);
            }
        }
    }
}

void CallbackBridge_nativeSendScreenSize(int width, int height) {
    windowWidth = width;
    windowHeight = height;
    
    if (isInputReady) {
        if (GLFW_invoke_FramebufferSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_FRAMEBUFFER_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_FramebufferSize((void*) showingWindow, width, height);
            }
        }
        if (GLFW_invoke_WindowSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_WINDOW_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_WindowSize((void*) showingWindow, width, height);
            }
        }
    }
    
    // return (isInputReady && (GLFW_invoke_FramebufferSize || GLFW_invoke_WindowSize));
}

void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset) {
    if (GLFW_invoke_Scroll && isInputReady) {
        if (isUseStackQueueCall) {
            sendDataFloat(EVENT_TYPE_SCROLL, xoffset, yoffset, 0, 0);
        } else {
            GLFW_invoke_Scroll((void*) showingWindow, (double) xoffset, (double) yoffset);
        }
    }
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(JNIEnv* env, jclass clazz, jlong window) {
    showingWindow = (long) window;
}

void CallbackBridge_pauseGameIfNeed() {
    if (isGrabbing) {
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 1, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 0, 0);
    }
}
