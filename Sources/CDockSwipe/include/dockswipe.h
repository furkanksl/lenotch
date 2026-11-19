#ifndef DOCKSWIPE_H
#define DOCKSWIPE_H

#include <stdbool.h>

typedef enum {
    DSDirectionLeft = 0,  /* towards the space with the lower index */
    DSDirectionRight = 1, /* towards the space with the higher index */
} DSDirection;

/** Installs the session event tap. Needs Accessibility permission. Safe to call again. */
bool ds_tap_install(void);

/**
 * Stops and joins the gesture worker, removes its sources and invalidates/releases its port.
 * Suppression is reset, so subsequent real swipes pass through. Safe to call again or reinstall.
 * Call lifecycle functions on the main thread, never from an event-tap callback.
 */
void ds_tap_uninstall(void);

/** When true, real trackpad horizontal Dock swipes are swallowed so the system animation never starts. */
void ds_tap_set_suppress(bool suppress);

/** Posts a synthetic Dock swipe that makes the Dock switch one space with no visible animation. */
bool ds_post_switch(DSDirection direction);

typedef enum {
    DSLiveSlideBegan = 1,
    DSLiveSlideChanged = 2,
    DSLiveSlideEnded = 4,
    DSLiveSlideCancelled = 8,
} DSLiveSlidePhase;

/** Posts one phase of a paced Dock swipe. Delta and position use Dock gesture units. */
bool ds_post_live_slide(DSLiveSlidePhase phase, DSDirection direction,
                        double delta, double position, double releaseVelocity);

/**
 * Called for a press of the shortcut for the space to the left or to the right.
 * It runs on the thread of the keyboard tap, not on the main thread, and must return at once.
 * Do not call install/uninstall from this callback. Marshal work onto the main thread instead.
 */
typedef void (*DSKeyHandler)(DSDirection direction);

/**
 * Installs the keyboard tap, on a thread of its own. Needs Accessibility permission. Safe to call again.
 * The tap does nothing until `ds_keys_configure` turns it on.
 */
bool ds_keys_install(DSKeyHandler handler);

/**
 * Disables interception, stops and joins the worker, then clears the handler and shortcuts.
 * No handler is running or can start after this returns. Safe to call again or reinstall.
 * Call on the main thread, never from the handler.
 */
void ds_keys_uninstall(void);

/**
 * Sets the two shortcuts: a virtual key code and the modifier flags (shift, control, option, command only).
 * A key code below 0 turns that direction off. With `enabled` false every key passes through.
 * A press that matches is swallowed, so macOS does not start its own transition, and the handler is called.
 */
void ds_keys_configure(bool enabled, int leftKeyCode, unsigned long long leftFlags,
                       int rightKeyCode, unsigned long long rightFlags);

/** True on macOS 27+, where synthetic swipes must carry the raw IOHID payload. */
bool ds_requires_event_augmentation(void);

#endif
