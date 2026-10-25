// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Plain value object describing the emulator configuration. The Swift app owns persistence
// (UserDefaults) and builds a PPSettings for every boot / runtime change. The bridge copies the
// values into Settings::values; nothing here touches the core by itself.

#import <Foundation/Foundation.h>
#import <PlanetCore/PPTypes.h>

NS_ASSUME_NONNULL_BEGIN

@interface PPSettings : NSObject <NSCopying>

/// Defaults tuned for iOS (see the per-property comments).
+ (instancetype)defaultSettings;

#pragma mark CPU / system (read at boot only)

/// Default PPCPUBackendAuto.
@property (nonatomic) PPCPUBackend cpuBackend;
/// Settings::values.is_new_3ds. Default YES (upstream default).
@property (nonatomic) BOOL isNew3DS;
/// Settings::values.region_value. Default PPRegionAuto.
@property (nonatomic) PPRegion region;
/// Settings::values.cpu_clock_percentage, clamped 5...400. Default 100. Also applied at runtime.
@property (nonatomic) NSInteger cpuClockPercentage;

#pragma mark Graphics

/// Settings::values.resolution_factor, clamped 0...10 (0 = automatic from window size).
/// Default 2. Runtime-changeable.
@property (nonatomic) NSInteger resolutionFactor;
/// Settings::values.async_shader_compilation. Default YES. Boot-time only.
@property (nonatomic) BOOL asyncShaderCompilation;
/// Settings::values.use_disk_shader_cache. Default YES. Boot-time only.
@property (nonatomic) BOOL useDiskShaderCache;
/// Settings::values.use_vsync. Default YES. Boot-time only.
@property (nonatomic) BOOL useVSync;
/// Settings::values.filter_mode (linear presentation filter). Default YES. Boot-time only.
@property (nonatomic) BOOL linearFiltering;
/// Settings::values.layout_option, used when the view is wider than tall. Default
/// PPScreenLayoutDefault (screens stacked vertically and centred, which leaves both sides of a
/// landscape iPhone free for the on-screen controls).
@property (nonatomic) PPScreenLayout landscapeLayout;
/// Settings::values.portrait_layout_option, used when the view is taller than wide.
/// Default TopFullWidth.
@property (nonatomic) PPPortraitLayout portraitLayout;
/// Settings::values.swap_screen. Default NO.
@property (nonatomic) BOOL swapScreens;
/// Settings::values.large_screen_proportion, clamped 1...16. Default 2.25 (like Android).
@property (nonatomic) float largeScreenProportion;

#pragma mark Speed

/// Settings::values.frame_limit in percent, clamped 0...1000 (0 = unlimited). Default 100.
@property (nonatomic) NSInteger frameLimitPercent;
/// Speed used while fast-forward is enabled (Settings::temporary_frame_limit), 0...1000.
/// Default 200.
@property (nonatomic) NSInteger turboSpeedPercent;

#pragma mark Audio

/// Settings::values.volume, clamped 0...1. Default 1.
@property (nonatomic) float volume;
/// Settings::values.enable_audio_stretching. Default YES.
@property (nonatomic) BOOL audioStretching;
/// When YES, Settings::values.input_type = Auto (real microphone through OpenAL, asks for
/// permission on first use). When NO, InputType::Null. Default NO. Boot-time only.
@property (nonatomic) BOOL microphoneEnabled;

@end

NS_ASSUME_NONNULL_END
