#import "VirtualDisplayRuntime.h"
#import <objc/runtime.h>

// CoreGraphics 里真实存在的两组私有 selector。
// 只声明不实现 —— clang 生成 objc_msgSend,运行时由系统框架提供。

@protocol _VSVDMode
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@protocol _VSVDisplay
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (uint32_t)displayID;
@end

NSObject *VSAllocVirtualDisplayMode(Class cls,
                                     uint32_t width,
                                     uint32_t height,
                                     double refreshRate) {
    if (![cls instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) {
        return nil;
    }
    id<_VSVDMode> instance = [[cls alloc] initWithWidth:width
                                                 height:height
                                            refreshRate:refreshRate];
    return (NSObject *)instance;
}

NSObject *VSAllocVirtualDisplay(Class cls, NSObject *descriptor) {
    if (![cls instancesRespondToSelector:@selector(initWithDescriptor:)]) {
        return nil;
    }
    id<_VSVDisplay> instance = [[cls alloc] initWithDescriptor:descriptor];
    return (NSObject *)instance;
}

BOOL VSVirtualDisplayApplySettings(NSObject *display, NSObject *settings) {
    if (![display respondsToSelector:@selector(applySettings:)]) return NO;
    return [(id<_VSVDisplay>)display applySettings:settings];
}

uint32_t VSVirtualDisplayGetID(NSObject *display) {
    if (![display respondsToSelector:@selector(displayID)]) return 0;
    return [(id<_VSVDisplay>)display displayID];
}

static void dump_class(const char *name) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:name]);
    if (!cls) { NSLog(@"[VSAPI] class %s not found", name); return; }
    NSLog(@"[VSAPI] === %s (super=%s) ===", name,
          class_getSuperclass(cls) ? class_getName(class_getSuperclass(cls)) : "nil");

    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        NSLog(@"[VSAPI]   -[%s %s]  types=%s", name,
              sel_getName(method_getName(ms[i])),
              method_getTypeEncoding(ms[i]));
    }
    free(ms);

    objc_property_t *ps = class_copyPropertyList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        NSLog(@"[VSAPI]   @property %s.%s  attr=%s", name,
              property_getName(ps[i]), property_getAttributes(ps[i]));
    }
    free(ps);

    Ivar *iv = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        NSLog(@"[VSAPI]   ivar %s.%s  type=%s", name,
              ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]));
    }
    free(iv);
}

void VSDumpVirtualDisplayAPI(void) {
    dump_class("CGVirtualDisplay");
    dump_class("CGVirtualDisplayDescriptor");
    dump_class("CGVirtualDisplaySettings");
    dump_class("CGVirtualDisplayMode");
}
