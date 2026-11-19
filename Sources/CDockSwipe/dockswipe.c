/*
 * Synthetic Dock swipe posting and real-swipe suppression.
 *
 * The event format, the macOS 27 IOHID payload, and the tap pass-through rules
 * are adapted from InstantSpaceSwitcher (https://github.com/jurplel/InstantSpaceSwitcher).
 *
 * MIT License
 *
 * Copyright (c) 2026 jurplel
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include "include/dockswipe.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// MARK: - Private event constants

static const CGEventField kCGSEventTypeField = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType = (CGEventField)110;
static const CGEventField kCGEventGestureSwipeMask = (CGEventField)115;
static const CGEventField kCGEventGestureSwipeMotion = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;
static const CGEventField kCGEventGestureSwipePositionX = (CGEventField)125;
static const CGEventField kCGEventGestureSwipePositionY = (CGEventField)126;
static const CGEventField kCGEventGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kCGEventGesturePhase = (CGEventField)132;
static const CGEventField kCGEventGesturePhaseAlias = (CGEventField)134;
static const CGEventField kCGEventGestureZoomDeltaY = (CGEventField)138;
static const CGEventField kCGEventSourceUnixProcessIDAlias = (CGEventField)169;

static const uint32_t kIOHIDEventTypeDockSwipe = 23;
static const uint32_t kIOHIDEventTypeVelocity = 9;
static const uint32_t kIOHIDEventTypeFluidTouchGesture = 23;
static const uint16_t kIOHIDGestureFlavorDockPrimary = 3;

enum {
    kCGSEventGesture = 29,
    kCGSEventDockControl = 30,
};

enum {
    kCGSGesturePhaseBegan = 1,
    kCGSGesturePhaseChanged = 2,
    kCGSGesturePhaseEnded = 4,
    kCGSGesturePhaseCancelled = 8,
};

static const uint16_t kCGGestureMotionHorizontal = 1;

// Smallest non-zero 16.16 progress: keeps the direction, leaves the Dock nothing to animate.
static const double kMinimalProgress = 0.000016;
// The fling on the ended phase is what commits the switch on macOS 27 (16.16 fixed point, max ~32767).
static const double kModernFlingVelocity = 9999.0;
static const double kLegacyVelocity = 2000.0;
// Our own events come back through the tap within milliseconds of being posted.
static const CFTimeInterval kSyntheticWindow = 1.0;

// MARK: - Owned event-tap workers

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    const char *name;
    CFMachPortRef port;
    CFRunLoopSourceRef source;
    CFRunLoopSourceRef stopSource;
    CFRunLoopRef runLoop;
    pthread_t thread;
    bool started;
    atomic_bool active;
    atomic_bool stopping;
} DSTap;

// Static callback contexts outlive every worker. Ports and sources stay retained until after join.
static DSTap gGestureTap = {
    .lock = PTHREAD_MUTEX_INITIALIZER, .ready = PTHREAD_COND_INITIALIZER,
    .name = "com.lenotch.app.spaces.gestures",
};
static DSTap gKeyTap = {
    .lock = PTHREAD_MUTEX_INITIALIZER, .ready = PTHREAD_COND_INITIALIZER,
    .name = "com.lenotch.app.spaces.keys",
};

static void stop_run_loop(void *context) {
    (void)context;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static void *tap_thread(void *context) {
    DSTap *tap = context;
    pthread_setname_np(tap->name);
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(loop, tap->source, kCFRunLoopCommonModes);
    CFRunLoopAddSource(loop, tap->stopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(tap->port, true);
    bool enabled = CFMachPortIsValid(tap->port) && CGEventTapIsEnabled(tap->port);

    pthread_mutex_lock(&tap->lock);
    tap->runLoop = (CFRunLoopRef)CFRetain(loop);
    atomic_store(&tap->active, enabled);
    pthread_cond_signal(&tap->ready);
    pthread_mutex_unlock(&tap->lock);

    // A signalled stop source also works if uninstall races the first CFRunLoopRun call.
    if (enabled && !atomic_load(&tap->stopping)) {
        CFRunLoopRun();
    }
    atomic_store(&tap->active, false);
    CGEventTapEnable(tap->port, false);
    CFRunLoopRemoveSource(loop, tap->source, kCFRunLoopCommonModes);
    CFRunLoopRemoveSource(loop, tap->stopSource, kCFRunLoopCommonModes);
    CFRunLoopSourceInvalidate(tap->source);
    CFRunLoopSourceInvalidate(tap->stopSource);
    CFMachPortInvalidate(tap->port);
    return NULL;
}

// The caller holds tap->lock. Only a non-worker lifecycle caller releases these resources.
static void release_tap(DSTap *tap) {
    if (tap->source) {
        CFRunLoopSourceInvalidate(tap->source);
        CFRelease(tap->source);
        tap->source = NULL;
    }
    if (tap->stopSource) {
        CFRunLoopSourceInvalidate(tap->stopSource);
        CFRelease(tap->stopSource);
        tap->stopSource = NULL;
    }
    if (tap->port) {
        CFMachPortInvalidate(tap->port);
        CFRelease(tap->port);
        tap->port = NULL;
    }
    if (tap->runLoop) {
        CFRelease(tap->runLoop);
        tap->runLoop = NULL;
    }
    tap->started = false;
    atomic_store(&tap->active, false);
}

static bool install_tap(DSTap *tap, CGEventTapLocation location, CGEventMask mask,
                        CGEventTapCallBack callback) {
    pthread_mutex_lock(&tap->lock);
    if (tap->started) {
        bool active = atomic_load(&tap->active) && !atomic_load(&tap->stopping);
        pthread_mutex_unlock(&tap->lock);
        return active;
    }
    atomic_store(&tap->stopping, false);
    tap->port = CGEventTapCreate(location, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                 mask, callback, tap);
    if (!tap->port) {
        fprintf(stderr, "Spaces: cannot create %s event tap; check Accessibility permission.\n", tap->name);
        pthread_mutex_unlock(&tap->lock);
        return false;
    }
    tap->source = CFMachPortCreateRunLoopSource(NULL, tap->port, 0);
    CFRunLoopSourceContext stopContext = {0};
    stopContext.perform = stop_run_loop;
    tap->stopSource = CFRunLoopSourceCreate(NULL, 0, &stopContext);
    if (!tap->source || !tap->stopSource) {
        fprintf(stderr, "Spaces: cannot create %s run-loop sources.\n", tap->name);
        release_tap(tap);
        pthread_mutex_unlock(&tap->lock);
        return false;
    }

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    // Every input event waits for this worker. Keep it joinable so uninstall can drain callbacks.
    pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
    int failed = pthread_create(&tap->thread, &attributes, tap_thread, tap);
    pthread_attr_destroy(&attributes);
    if (failed) {
        fprintf(stderr, "Spaces: cannot start %s worker: %s.\n", tap->name, strerror(failed));
        release_tap(tap);
        pthread_mutex_unlock(&tap->lock);
        return false;
    }
    tap->started = true;
    while (!tap->runLoop) {
        pthread_cond_wait(&tap->ready, &tap->lock);
    }
    bool enabled = atomic_load(&tap->active);
    if (!enabled) {
        fprintf(stderr, "Spaces: %s event tap did not become enabled.\n", tap->name);
        int failed = pthread_join(tap->thread, NULL);
        if (failed) {
            // Preserve the callback context and resources unless the worker is known to have exited.
            atomic_store(&tap->stopping, true);
            fprintf(stderr, "Spaces: cannot join %s worker: %s.\n", tap->name, strerror(failed));
        } else {
            release_tap(tap);
        }
    }
    pthread_mutex_unlock(&tap->lock);
    return enabled;
}

static bool uninstall_tap(DSTap *tap) {
    pthread_mutex_lock(&tap->lock);
    if (tap->started && pthread_equal(pthread_self(), tap->thread)) {
        // Joining this thread from its callback would deadlock. Nothing is released in that case.
        fprintf(stderr, "Spaces: uninstall %s on the main thread, not in its callback.\n", tap->name);
        pthread_mutex_unlock(&tap->lock);
        return false;
    }
    atomic_store(&tap->stopping, true);
    atomic_store(&tap->active, false);
    if (tap->started) {
        CFRunLoopSourceSignal(tap->stopSource);
        CFRunLoopWakeUp(tap->runLoop);
        // The worker never takes this lock after its startup handshake, including in callbacks.
        int failed = pthread_join(tap->thread, NULL);
        if (failed) {
            fprintf(stderr, "Spaces: cannot join %s worker: %s.\n", tap->name, strerror(failed));
            pthread_mutex_unlock(&tap->lock);
            return false;
        }
    }
    release_tap(tap);
    pthread_mutex_unlock(&tap->lock);
    return true;
}

// MARK: - State

// The gesture tap is on a thread of its own, so a busy main thread never holds back the gesture events
// of other apps. Everything the posting/lifecycle thread and the callback share is atomic.
static atomic_bool gSuppress = false;
static atomic_bool gTracking = false;
static atomic_uint gSyntheticToPass = 0;
static _Atomic(CFAbsoluteTime) gLastPostTime = 0;
static atomic_int gNaturalScrolling = -1;
// Lifecycle calls are main-thread only.
static bool gObservingNaturalScrolling = false;

// Tell static analyzers about the retained result without changing upstream serialization.
static CGEventRef augment_event(CGEventRef event) CF_RETURNS_RETAINED;

// MARK: - macOS 27 payload

#pragma pack(push, 1)

typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} IOHIDEventBase;

typedef struct {
    IOHIDEventBase base;
    int32_t position_x;
    int32_t position_y;
    int32_t position_z;
    uint32_t swipe_mask;
    uint16_t gesture_motion;
    uint16_t gesture_flavor;
    int32_t swipe_progress;
} IOHIDFluidTouchGestureData;

typedef struct {
    IOHIDEventBase base;
    int32_t velocity_x;
    int32_t velocity_y;
    int32_t velocity_z;
} IOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t sender_id;
    uint32_t options;
    uint32_t attribute_length;
    uint32_t event_count;
} IOHIDSystemQueueElementHeader;

#pragma pack(pop)

_Static_assert(sizeof(IOHIDEventBase) == 16, "unexpected IOHID event base layout");
_Static_assert(sizeof(IOHIDFluidTouchGestureData) == 40, "unexpected IOHID fluid gesture layout");
_Static_assert(sizeof(IOHIDVelocityEventData) == 28, "unexpected IOHID velocity layout");
_Static_assert(sizeof(IOHIDSystemQueueElementHeader) == 28, "unexpected IOHID queue header layout");

static int32_t to_fixed1616(double value) {
    int32_t fixed = (int32_t)(value * 65536.0);
    if (fixed == 0 && value != 0.0) {
        return value > 0.0 ? 1 : -1;
    }
    return fixed;
}

static uint8_t *make_iohid_payload(CGEventRef event, size_t *outLength) {
    int64_t phase = CGEventGetIntegerValueField(event, kCGEventGesturePhase);
    int64_t motion = CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
    double progress = CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
    double posX = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionX);
    double posY = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionY);
    double velX = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
    double velY = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityY);
    int64_t swipeMask = CGEventGetIntegerValueField(event, kCGEventGestureSwipeMask);

    bool includeVelocity = (velX != 0.0 || velY != 0.0 || phase == kCGSGesturePhaseEnded);
    size_t length = sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData);
    if (includeVelocity) {
        length += sizeof(IOHIDVelocityEventData);
    }

    uint8_t *payload = (uint8_t *)calloc(1, length);
    if (!payload) {
        return NULL;
    }

    IOHIDSystemQueueElementHeader *header = (IOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp != 0 ? timestamp : mach_absolute_time();
    header->event_count = includeVelocity ? 2 : 1;

    IOHIDFluidTouchGestureData *fluid =
        (IOHIDFluidTouchGestureData *)(payload + sizeof(IOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(IOHIDFluidTouchGestureData);
    fluid->base.type = kIOHIDEventTypeFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->position_x = to_fixed1616(posX);
    fluid->position_y = to_fixed1616(posY);
    fluid->swipe_mask = (uint32_t)swipeMask;
    fluid->gesture_motion = (uint16_t)motion;
    fluid->gesture_flavor = kIOHIDGestureFlavorDockPrimary;
    fluid->swipe_progress = to_fixed1616(progress);

    if (includeVelocity) {
        IOHIDVelocityEventData *velocity = (IOHIDVelocityEventData *)(
            payload + sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(IOHIDVelocityEventData);
        velocity->base.type = kIOHIDEventTypeVelocity;
        velocity->base.depth = 1;
        velocity->velocity_x = to_fixed1616(velX);
        velocity->velocity_y = to_fixed1616(velY);
    }

    *outLength = length;
    return payload;
}

/// Appends the IOHID payload (field 4205) to the serialized event. Returns a retained event.
static CGEventRef augment_event(CGEventRef event) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) {
        return NULL;
    }

    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);

    // Serialized format version 2 only.
    if (length < 4 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = make_iohid_payload(event, &payloadLength);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    size_t newLength = (size_t)length + 4 + payloadLength;
    uint8_t *newBytes = (uint8_t *)malloc(newLength);
    if (!newBytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }

    memcpy(newBytes, bytes, (size_t)length);
    // 4-byte tag: payload size, then field ID 4205, both big-endian.
    newBytes[length] = (uint8_t)((payloadLength >> 8) & 0xFF);
    newBytes[length + 1] = (uint8_t)(payloadLength & 0xFF);
    newBytes[length + 2] = (uint8_t)((4205 >> 8) & 0xFF);
    newBytes[length + 3] = (uint8_t)(4205 & 0xFF);
    memcpy(newBytes + length + 4, payload, payloadLength);

    free(payload);
    CFRelease(data);

    CFDataRef newData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!newData) {
        return NULL;
    }

    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, newData);
    CFRelease(newData);
    return result;
}

bool ds_requires_event_augmentation(void) {
    static atomic_int cached = -1;
    int result = atomic_load(&cached);
    if (result != -1) {
        return result != 0;
    }

    char version[32] = {0};
    size_t size = sizeof(version);
    int major = 0;
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) != 0 ||
        sscanf(version, "%d", &major) < 1) {
        atomic_store(&cached, 0);
        return false;
    }

    result = (major >= 27) ? 1 : 0;
    atomic_store(&cached, result);
    return result != 0;
}

// MARK: - Posting

static void natural_scrolling_changed(CFNotificationCenterRef center, void *observer,
                                      CFNotificationName name, const void *object,
                                      CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if (!atomic_load(&gGestureTap.active)) return;
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    atomic_store(&gNaturalScrolling, -1);
}

// On macOS 27 "right" is negative, and the Dock reads the posted sign through the
// natural scrolling preference, so it flips again with natural scrolling off.
static double modern_swipe_sign(DSDirection direction) {
    int naturalScrolling = atomic_load(&gNaturalScrolling);
    if (naturalScrolling < 0) {
        Boolean valid = false;
        Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
                                                          kCFPreferencesAnyApplication, &valid);
        naturalScrolling = (!valid || natural) ? 1 : 0;
        atomic_store(&gNaturalScrolling, naturalScrolling);
    }
    const double sign = (direction == DSDirectionRight) ? -1.0 : 1.0;
    return naturalScrolling ? sign : -sign;
}

static bool post_modern(int phase, double delta, double position, double velocity, bool with_companion) {
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) {
        return false;
    }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, delta);
    // Fields a real trackpad swipe carries.
    CGEventSetIntegerValueField(ev, kCGEventGesturePhaseAlias, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureZoomDeltaY, 3.0);
    CGEventSetDoubleValueField(ev, kCGEventSourceUnixProcessIDAlias, (double)mach_absolute_time());
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipePositionX, position);
    if (phase == kCGSGesturePhaseEnded) {
        CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, velocity);
    }

    CGEventRef augmented = augment_event(ev);
    CFRelease(ev);
    if (!augmented) {
        return false;
    }

    // Keep Instant's existing companion. macOS 27 does not need it for continuous swipes.
    CGEventRef companion = with_companion ? CGEventCreate(NULL) : NULL;
    if (with_companion && !companion) {
        CFRelease(augmented);
        return false;
    }
    if (companion) CGEventSetIntegerValueField(companion, kCGSEventTypeField, kCGSEventGesture);

    if (atomic_load(&gGestureTap.active)) {
        // Before the events are posted: the tap thread can get them at once.
        atomic_fetch_add(&gSyntheticToPass, companion ? 2 : 1);
    }
    CGEventPost(kCGSessionEventTap, augmented);
    if (companion) {
        CGEventPost(kCGSessionEventTap, companion);
        CFRelease(companion);
    }
    CFRelease(augmented);
    return true;
}

static bool post_legacy(int phase, double delta, double velocityX, double velocityY) {
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) {
        return false;
    }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, delta);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, velocityX);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, velocityY);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
    return true;
}

static bool post_phase(int phase, DSDirection direction) {
    if (ds_requires_event_augmentation()) {
        double sign = modern_swipe_sign(direction);
        return post_modern(phase, sign * kMinimalProgress, 0.1, sign * kModernFlingVelocity, true);
    }
    double sign = direction == DSDirectionRight ? 1.0 : -1.0;
    return post_legacy(phase, sign * kMinimalProgress, sign * kLegacyVelocity, sign * kLegacyVelocity);
}

bool ds_post_switch(DSDirection direction) {
    // All three phases are needed; with only began + ended Mission Control breaks.
    atomic_store(&gLastPostTime, CFAbsoluteTimeGetCurrent());
    return post_phase(kCGSGesturePhaseBegan, direction)
        && post_phase(kCGSGesturePhaseChanged, direction)
        && post_phase(kCGSGesturePhaseEnded, direction);
}

bool ds_post_live_slide(DSLiveSlidePhase phase, DSDirection direction,
                        double delta, double position, double releaseVelocity) {
    if ((phase != DSLiveSlideBegan && phase != DSLiveSlideChanged && phase != DSLiveSlideEnded &&
         phase != DSLiveSlideCancelled) || !isfinite(delta) || !isfinite(position) || !isfinite(releaseVelocity) ||
        delta < 0 || delta > 2 || position < 0 || position > 2 || releaseVelocity < 0 || releaseVelocity > 10000) {
        return false;
    }
    atomic_store(&gLastPostTime, CFAbsoluteTimeGetCurrent());
    if (ds_requires_event_augmentation()) {
        double sign = modern_swipe_sign(direction);
        // The HID progress field is the total since Begin, including during release.
        return post_modern(phase, sign * position, 0.0, sign * releaseVelocity, false);
    }
    double sign = direction == DSDirectionRight ? 1.0 : -1.0;
    return post_legacy(phase, sign * delta, sign * releaseVelocity, 0);
}

// MARK: - Gesture suppression

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    DSTap *tap = refcon;
    if (atomic_load(&tap->stopping)) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(tap->port, true);
        // Anything posted while the tap was disabled never reaches us.
        atomic_store(&gSyntheticToPass, 0);
        return event;
    }

    uint32_t eventType = (uint32_t)CGEventGetIntegerValueField(event, kCGSEventTypeField);
    bool isGestureEvent = (eventType == kCGSEventDockControl || eventType == kCGSEventGesture);

    // A count left over after the burst would let real swipes slip past the suppression.
    // The count is read before the time. If the main thread posts a new swipe between the two reads, the
    // time is new and nothing is cleared. If it posts after them, the count has changed and the exchange
    // fails. So a swipe that is being posted now never loses its count.
    unsigned int pending = atomic_load(&gSyntheticToPass);
    if (pending > 0 && CFAbsoluteTimeGetCurrent() - atomic_load(&gLastPostTime) > kSyntheticWindow) {
        atomic_compare_exchange_strong(&gSyntheticToPass, &pending, 0);
    }

    // On macOS 27 our own swipes re-enter the tap with sourcePid == 0, so count them out.
    if (isGestureEvent) {
        pending = atomic_load(&gSyntheticToPass);
        while (pending > 0) {
            // On failure `pending` gets the current count, and the loop tries again.
            if (atomic_compare_exchange_weak(&gSyntheticToPass, &pending, pending - 1)) {
                return event;
            }
        }
    }

    if (!atomic_load(&gSuppress)) {
        atomic_store(&gTracking, false);
        return event;
    }

    // Real trackpad gesture events have sourcePid == 0 (HID). Leave other synthetic events alone.
    if (isGestureEvent) {
        pid_t sourcePid = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
        if (sourcePid != 0) return event;
    }

    if (eventType == kCGSEventDockControl) {
        uint32_t hidType = (uint32_t)CGEventGetIntegerValueField(event, kCGEventGestureHIDType);
        if (hidType != kIOHIDEventTypeDockSwipe) return event;

        uint16_t motion = (uint16_t)CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
        if (motion != kCGGestureMotionHorizontal) return event;

        int64_t phase = CGEventGetIntegerValueField(event, kCGEventGesturePhase);
        switch (phase) {
        case kCGSGesturePhaseBegan:
            atomic_store(&gTracking, true);
            return NULL;

        case kCGSGesturePhaseEnded:
            if (!atomic_exchange(&gTracking, false)) return event;
            if (ds_requires_event_augmentation()) {
                // On macOS 27 the Dock needs the real ended event to close its gesture
                // state. Zero the motion so it does not switch by itself.
                CGEventSetDoubleValueField(event, kCGEventGestureSwipeProgress, 0.0);
                CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityX, 0.0);
                CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityY, 0.0);
                return event;
            }
            return NULL;

        case kCGSGesturePhaseCancelled:
            if (!atomic_exchange(&gTracking, false)) return event;
            return NULL;

        default:
            return atomic_load(&gTracking) ? NULL : event;
        }
    }

    // Companion gesture events of a swipe we are swallowing.
    if (eventType == kCGSEventGesture && atomic_load(&gTracking)) {
        return NULL;
    }

    return event;
}

bool ds_tap_install(void) {
    CGEventMask mask = (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
    if (!install_tap(&gGestureTap, kCGSessionEventTap, mask, tap_callback)) return false;
    if (!gObservingNaturalScrolling) {
        atomic_store(&gNaturalScrolling, -1);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), &gNaturalScrolling,
                                        natural_scrolling_changed,
                                        CFSTR("SwipeScrollDirectionDidChangeNotification"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        gObservingNaturalScrolling = true;
    }
    return true;
}

void ds_tap_uninstall(void) {
    ds_tap_set_suppress(false);
    if (gObservingNaturalScrolling) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDistributedCenter(), &gNaturalScrolling,
                                           CFSTR("SwipeScrollDirectionDidChangeNotification"), NULL);
        gObservingNaturalScrolling = false;
    }
    if (!uninstall_tap(&gGestureTap)) return;
    atomic_store(&gTracking, false);
    atomic_store(&gSyntheticToPass, 0);
    atomic_store(&gLastPostTime, 0);
    atomic_store(&gNaturalScrolling, -1);
}

void ds_tap_set_suppress(bool suppress) {
    atomic_store(&gSuppress, suppress);
    if (!suppress) {
        atomic_store(&gTracking, false);
    }
}

// MARK: - Keyboard shortcuts

// Every key press waits for this callback. Shared configuration and the handler are atomic.
static const CGEventFlags kShortcutModifiers =
    kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;

static _Atomic(DSKeyHandler) gKeyHandler = NULL;
static atomic_bool gKeysEnabled = false;
// Index 0 is left, 1 is right, as in DSDirection.
static atomic_int gKeyCode[2] = {-1, -1};
static atomic_ullong gKeyFlags[2] = {0, 0};
// The key down was swallowed, so its key up must be too while interception stays enabled.
static atomic_bool gKeyHeld[2] = {false, false};

static CGEventRef key_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    DSTap *tap = refcon;
    if (atomic_load(&tap->stopping)) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(tap->port, true);
        return event;
    }
    if (!atomic_load(&gKeysEnabled) || (type != kCGEventKeyDown && type != kCGEventKeyUp)) {
        return event;
    }

    int code = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (type == kCGEventKeyUp) {
        for (int direction = 0; direction < 2; direction++) {
            if (code == atomic_load(&gKeyCode[direction]) && atomic_exchange(&gKeyHeld[direction], false)) {
                return NULL;
            }
        }
        return event;
    }

    unsigned long long flags = (unsigned long long)(CGEventGetFlags(event) & kShortcutModifiers);
    for (int direction = 0; direction < 2; direction++) {
        int wanted = atomic_load(&gKeyCode[direction]);
        if (wanted < 0 || code != wanted || flags != atomic_load(&gKeyFlags[direction])) {
            continue;
        }
        atomic_store(&gKeyHeld[direction], true);
        // A key that is held down sends the press again and again. Only the first one is a step.
        bool isRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
        DSKeyHandler handler = atomic_load(&gKeyHandler);
        if (!isRepeat && handler && atomic_load(&gKeysEnabled) && !atomic_load(&tap->stopping)) {
            handler(direction == 0 ? DSDirectionLeft : DSDirectionRight);
        }
        return atomic_load(&gKeysEnabled) && !atomic_load(&tap->stopping) ? NULL : event;
    }
    return event;
}

bool ds_keys_install(DSKeyHandler handler) {
    if (!handler) return false;
    atomic_store(&gKeyHandler, handler);
    // Where key events enter the window server: before macOS reads them as its own shortcuts.
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    bool installed = install_tap(&gKeyTap, kCGHIDEventTap, mask, key_tap_callback);
    if (!installed) atomic_store(&gKeyHandler, NULL);
    return installed;
}

void ds_keys_uninstall(void) {
    atomic_store(&gKeysEnabled, false);
    if (!uninstall_tap(&gKeyTap)) return;
    atomic_store(&gKeyHandler, NULL);
    ds_keys_configure(false, -1, 0, -1, 0);
}

void ds_keys_configure(bool enabled, int leftKeyCode, unsigned long long leftFlags,
                       int rightKeyCode, unsigned long long rightFlags) {
    atomic_store(&gKeysEnabled, false);
    atomic_store(&gKeyHeld[0], false);
    atomic_store(&gKeyHeld[1], false);
    atomic_store(&gKeyCode[0], leftKeyCode);
    atomic_store(&gKeyFlags[0], leftFlags & kShortcutModifiers);
    atomic_store(&gKeyCode[1], rightKeyCode);
    atomic_store(&gKeyFlags[1], rightFlags & kShortcutModifiers);
    atomic_store(&gKeysEnabled, enabled && atomic_load(&gKeyTap.active));
}
