// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// UIKit implementation of AppleUtils for iOS. Azahar's apple_utils.mm uses Cocoa (NSScreen,
// CGDisplay*) which does not exist on iOS; scripts/patch_azahar.py copies this file into
// azahar's src/common/ and compiles it instead on iOS.
//
// Valid with and without ARC (azahar's own targets are built without -fobjc-arc).

#include <atomic>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "common/apple_utils.h"

namespace {

std::atomic<float> g_refresh_rate{0.0f};

float ReadRefreshRateOnMainThread() {
    const NSInteger fps = UIScreen.mainScreen.maximumFramesPerSecond;
    const float value = fps > 0 ? static_cast<float>(fps) : 60.0f;
    g_refresh_rate.store(value);
    return value;
}

// UIKit must only be touched on the main thread; prime the cache as soon as the main queue runs.
__attribute__((constructor)) void PrimeRefreshRateCache() {
    dispatch_async(dispatch_get_main_queue(), ^{
      ReadRefreshRateOnMainThread();
    });
}

} // namespace

namespace AppleUtils {

float GetRefreshRate() {
    if ([NSThread isMainThread]) {
        return ReadRefreshRateOnMainThread();
    }
    const float cached = g_refresh_rate.load();
    return cached > 0.0f ? cached : 60.0f;
}

int IsLowPowerModeEnabled() {
    return NSProcessInfo.processInfo.lowPowerModeEnabled ? 1 : 0;
}

} // namespace AppleUtils
