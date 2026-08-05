#import "SurfaceViewController.h"

#include "jni.h"
#include <assert.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "EGL/egl.h"
#include "EGL/eglext.h"
#include "GL/osmesa.h"

#include "glfw_keycodes.h"
#include "ctxbridges/bridge_tbl.h"
#include "ctxbridges/osmesa_internal.h"
#include "utils.h"
#include "ZinkConfig.h"

int clientAPI;

void JNI_LWJGL_changeRenderer(const char* value_c) {
    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring value = (*env)->NewStringUTF(env, value_c);
    jclass clazz = (*env)->FindClass(env, "java/lang/System");
    jmethodID method = (*env)->GetStaticMethodID(env, clazz, "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    (*env)->CallStaticObjectMethod(env, clazz, method, key, value);
}

void pojavTerminate() {
    CallbackBridge_nativeSetInputReady(NO);
    if (!br_terminate) return;
    br_terminate();
}

void* pojavGetCurrentContext() {
    return br_get_current();
}

int pojavInit(BOOL useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = 1;
    isUseStackQueueCall = useStackQueue;
    return JNI_TRUE;
}

int pojavInitOpenGL() {
    NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    BOOL isAuto = [renderer isEqualToString:@"auto"];
    if (isAuto || [renderer isEqualToString:@ RENDERER_NAME_GL4ES]) {
        // At this point, if renderer is still auto (unspecified major version), pick gl4es
        renderer = @ RENDERER_NAME_GL4ES;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {
        renderer = @ RENDERER_NAME_MOBILEGLUES;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE]) {
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_LTW]) {
        // Pre-load ANGLE as host EGL before LTW, so LTW's constructor
        // finds eglGetProcAddress via RTLD_DEFAULT.
        dlopen("@rpath/libtinygl4angle.dylib", RTLD_GLOBAL);
        set_gl_bridge_tbl();
    } else if ([renderer hasPrefix:@"libOSMesa"]) {
        setenv("GALLIUM_DRIVER","zink",1);
        [ZinkConfig applyZinkEnvironmentFromPreferences];
        // Pre-load Vulkan loader for Zink before Mesa initializes
        NSString *vkPath = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libvulkan.1.dylib"];
        dlopen(vkPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        set_osm_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VULKAN]) {
        set_vk_bridge_tbl();
    }
    JNI_LWJGL_changeRenderer(renderer.UTF8String);

    // Preload renderer library
    // Use RTLD_LOCAL instead of RTLD_GLOBAL for OSMesa/Zink to prevent
    // symbol collision with SDL3's OpenGL backend in Minecraft 26.3+.
    // SDL3 (used by LWJGL 3.4.1) creates its own GL context and will crash
    // with "OpenGL library already loaded" if it finds our symbols globally.
    int dlopen_flags = [renderer hasPrefix:@"libOSMesa"] ? RTLD_LOCAL : RTLD_GLOBAL;
    void* handle = dlopen([NSString stringWithFormat:@"@rpath/%@", renderer].UTF8String, dlopen_flags);
    if (!handle) {
        NSLog(@"[egl_bridge] Warning: Failed to preload renderer %@: %s", renderer, dlerror());
    }

    return !br_init();
    //return 0;
}

void pojavSetWindowHint(int hint, int value) {
    if (hint == GLFW_CLIENT_API) {
        clientAPI = value;
    } else if (strcmp(getenv("AMETHYST_RENDERER"), "auto")==0 && hint == GLFW_CONTEXT_VERSION_MAJOR) {
        switch (value) {
            case 1:
            case 2:
                setenv("AMETHYST_RENDERER", RENDERER_NAME_GL4ES, 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_GL4ES);
                break;
            // case 4: use Zink?
            default:
                setenv("AMETHYST_RENDERER", RENDERER_NAME_MOBILEGLUES, 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
                break;
        }
    }
}

void pojavSwapBuffers() {
    if (!br_swap_buffers) return;
    br_swap_buffers();
}

void pojavMakeCurrent(basic_render_window_t* window) {
    if (!br_make_current) return;
    /* [Amethyst diag] Marker: did our bridge get asked to make the GL context
     * current in MC 26.3+? If this never prints, SDL3 owns the context and the
     * OSMesa-bridge diagnostic in osm_make_current will also not fire. */
    fprintf(stderr, "[GLDiag] pojavMakeCurrent window=%p\n", (void*)window);
    fflush(stderr);
    br_make_current(window);
}

void* pojavCreateContext(basic_render_window_t* contextSrc) {
    if (clientAPI == GLFW_NO_API) {
        // Game has selected Vulkan API to render
        return (__bridge void *)SurfaceViewController.surface.layer;
    }

    static BOOL inited = NO;
    if (!inited) {
        inited = YES;
        pojavInitOpenGL();
    }

    basic_render_window_t* ctx = br_init_context(contextSrc);
    if (ctx) {
        pojavMakeCurrent(ctx);
    }
    return ctx;
}

void pojavSwapInterval(int interval) {
    if (!br_swap_interval) return;
    br_swap_interval(interval);
}
