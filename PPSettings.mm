// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.

#include <algorithm>

#include "audio_core/input_details.h"
#include "audio_core/sink_details.h"
#include "common/settings.h"
#include "core/hle/service/service.h"

#import "PPInternal.h"

@implementation PPSettings

+ (instancetype)defaultSettings {
    return [[PPSettings alloc] init];
}

- (instancetype)init {
    if ((self = [super init])) {
        _cpuBackend = PPCPUBackendAuto;
        _isNew3DS = YES;
        _region = PPRegionAuto;
        _cpuClockPercentage = 100;

        _resolutionFactor = 2;
        _asyncShaderCompilation = YES;
        _useDiskShaderCache = YES;
        _useVSync = YES;
        _linearFiltering = YES;
        _landscapeLayout = PPScreenLayoutDefault;
        _portraitLayout = PPPortraitLayoutTopFullWidth;
        _swapScreens = NO;
        _largeScreenProportion = 2.25f;

        _frameLimitPercent = 100;
        _turboSpeedPercent = 200;

        _volume = 1.0f;
        _audioStretching = YES;
        _microphoneEnabled = NO;
    }
    return self;
}

- (id)copyWithZone:(NSZone*)zone {
    PPSettings* copy = [[PPSettings allocWithZone:zone] init];
    copy.cpuBackend = self.cpuBackend;
    copy.isNew3DS = self.isNew3DS;
    copy.region = self.region;
    copy.cpuClockPercentage = self.cpuClockPercentage;
    copy.resolutionFactor = self.resolutionFactor;
    copy.asyncShaderCompilation = self.asyncShaderCompilation;
    copy.useDiskShaderCache = self.useDiskShaderCache;
    copy.useVSync = self.useVSync;
    copy.linearFiltering = self.linearFiltering;
    copy.landscapeLayout = self.landscapeLayout;
    copy.portraitLayout = self.portraitLayout;
    copy.swapScreens = self.swapScreens;
    copy.largeScreenProportion = self.largeScreenProportion;
    copy.frameLimitPercent = self.frameLimitPercent;
    copy.turboSpeedPercent = self.turboSpeedPercent;
    copy.volume = self.volume;
    copy.audioStretching = self.audioStretching;
    copy.microphoneEnabled = self.microphoneEnabled;
    return copy;
}

@end

namespace PlanetPort {

namespace {

Settings::LayoutOption ToLayoutOption(PPScreenLayout layout) {
    switch (layout) {
    case PPScreenLayoutSingleScreen:
        return Settings::LayoutOption::SingleScreen;
    case PPScreenLayoutLargeScreen:
        return Settings::LayoutOption::LargeScreen;
    case PPScreenLayoutSideScreen:
        return Settings::LayoutOption::SideScreen;
    case PPScreenLayoutHybridScreen:
        return Settings::LayoutOption::HybridScreen;
    case PPScreenLayoutDefault:
    default:
        return Settings::LayoutOption::Default;
    }
}

Settings::PortraitLayoutOption ToPortraitLayout(PPPortraitLayout layout) {
    switch (layout) {
    case PPPortraitLayoutOriginal:
        return Settings::PortraitLayoutOption::PortraitOriginal;
    case PPPortraitLayoutTopFullWidth:
    default:
        return Settings::PortraitLayoutOption::PortraitTopFullWidth;
    }
}

template <typename T>
T Clamp(T value, T lo, T hi) {
    return std::clamp(value, lo, hi);
}

} // namespace

void ApplyGlobalDefaults() {
    // Service::Init reads lle_modules.at(name) for every module: the map must be complete
    // before the first System::Load (same as the libretro frontend).
    for (const auto& service_module : Service::service_module_map) {
        Settings::values.lle_modules.emplace(service_module.name, false);
    }

    // No camera support on iOS yet: "blank" selects BlankCamera without logging errors.
    for (auto& name : Settings::values.camera_name) {
        name = "blank";
    }

    Settings::values.use_virtual_sd = true;
    Settings::values.output_type = AudioCore::SinkType::Auto;
    Settings::values.input_type = AudioCore::InputType::Null;
    Settings::values.graphics_api = Settings::GraphicsAPI::Vulkan;
    Settings::values.use_display_refresh_rate_detection = true;
    Settings::values.enable_rpc_server = false;
    Settings::values.plugin_loader_enabled = false;
    Settings::values.log_filter = std::string("*:Info");
}

void ApplyRuntimeSettingsToValues(PPSettings* settings) {
    if (settings == nil) {
        return;
    }
    Settings::values.frame_limit =
        static_cast<double>(Clamp<NSInteger>(settings.frameLimitPercent, 0, 1000));
    Settings::values.volume = Clamp(settings.volume, 0.0f, 1.0f);
    Settings::values.enable_audio_stretching = static_cast<bool>(settings.audioStretching);
    Settings::values.cpu_clock_percentage =
        static_cast<s32>(Clamp<NSInteger>(settings.cpuClockPercentage, 5, 400));
    Settings::values.resolution_factor =
        static_cast<u32>(Clamp<NSInteger>(settings.resolutionFactor, 0, 10));
    Settings::values.layout_option = ToLayoutOption(settings.landscapeLayout);
    Settings::values.portrait_layout_option = ToPortraitLayout(settings.portraitLayout);
    Settings::values.swap_screen = static_cast<bool>(settings.swapScreens);
    Settings::values.large_screen_proportion = Clamp(settings.largeScreenProportion, 1.0f, 16.0f);
}

void ApplyBootSettings(PPSettings* settings, bool use_jit) {
    PPSettings* s = settings ?: [PPSettings defaultSettings];

    // CPU / system.
    Settings::values.use_cpu_jit = use_jit;
    Settings::values.use_shader_jit = use_jit;
    Settings::values.use_fastinterp = true;
    Settings::values.is_new_3ds = static_cast<bool>(s.isNew3DS);
    const NSInteger region = Clamp<NSInteger>(s.region, -1, 6);
    Settings::values.region_value = static_cast<s32>(region);

    // Graphics (boot-time only values).
    Settings::values.graphics_api = Settings::GraphicsAPI::Vulkan;
    Settings::values.async_shader_compilation = static_cast<bool>(s.asyncShaderCompilation);
    Settings::values.use_disk_shader_cache = static_cast<bool>(s.useDiskShaderCache);
    Settings::values.use_vsync = static_cast<bool>(s.useVSync);
    Settings::values.filter_mode = static_cast<bool>(s.linearFiltering);
    Settings::values.async_presentation = true;
    Settings::values.use_hw_shader = true;

    // Audio input.
    Settings::values.input_type =
        s.microphoneEnabled ? AudioCore::InputType::Auto : AudioCore::InputType::Null;

    // Everything that can also change at runtime. (The temporary frame limit / fast-forward is
    // owned by PPEmulator.mm and deliberately not touched here.)
    ApplyRuntimeSettingsToValues(s);
}

} // namespace PlanetPort
