// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// PRIVATE header shared by the Objective-C++ translation units of the bridge.
// Never installed in the framework. Every declaration here has exactly one owner file
// (noted per section); other files only call it.

#pragma once

#ifndef __cplusplus
#error "PPInternal.h is Objective-C++ only"
#endif

#import <Foundation/Foundation.h>
#import <PlanetCore/PPTypes.h>
#import <PlanetCore/PPSettings.h>
#import <PlanetCore/PPGameInfo.h>
#import <PlanetCore/PPEmulator.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace Frontend {
class SoftwareKeyboard;
}

NS_ASSUME_NONNULL_BEGIN

namespace PlanetPort {

// ---------------------------------------------------------------------------------------------
// Owner: PPCommon.mm
// ---------------------------------------------------------------------------------------------

/// UTF-8 conversions. nil -> "" and "" -> @"".
NSString* ToNSString(const std::string& s);
std::string ToStdString(NSString* _Nullable s);

/// Builds an NSError in PPErrorDomain. `message` is the Italian NSLocalizedDescriptionKey.
/// `core_details` (if non-empty) goes to PPErrorCoreDetailsKey.
NSError* MakeError(PPErrorCode code, NSString* message, const std::string& core_details = {});

/// Runs `block` on the main queue asynchronously (never synchronously, to avoid deadlocks with
/// code on the main thread that joins the emulation thread).
void RunOnMain(dispatch_block_t block);

// ---------------------------------------------------------------------------------------------
// Owner: PPEmulator.mm (prepare logic lives there)
// ---------------------------------------------------------------------------------------------

/// YES after a successful -[PPEmulator prepareWithUserDirectory:error:].
bool IsPrepared();
/// Absolute user directory with trailing '/'. Empty before prepare.
const std::string& UserDirectory();
/// YES while a game is booting/running/stopping (state != Idle). Thread-safe.
bool IsGameActive();

// ---------------------------------------------------------------------------------------------
// Owner: PPSettings.mm
// ---------------------------------------------------------------------------------------------

/// One-time defaults written into Settings::values during prepare (before any boot):
/// lle_modules filled from Service::service_module_map (all false), camera_name[*] = "blank",
/// use_virtual_sd = true, output_type = Auto, input_type = Null, graphics_api = Vulkan,
/// use_display_refresh_rate_detection = true, enable_rpc_server = false, log_filter "*:Info".
void ApplyGlobalDefaults();

/// Copies every PPSettings value into Settings::values before System::Load (emulation thread or
/// main thread while Idle). `use_jit` decides use_cpu_jit / use_shader_jit
/// (use_fastinterp is always true).
void ApplyBootSettings(PPSettings* settings, bool use_jit);

/// Copies only the runtime-changeable values into Settings::values (frame_limit, volume,
/// enable_audio_stretching, cpu_clock_percentage, resolution_factor, layout_option,
/// portrait_layout_option, swap_screen, large_screen_proportion). Does NOT call ApplySettings.
void ApplyRuntimeSettingsToValues(PPSettings* settings);

// ---------------------------------------------------------------------------------------------
// Owner: PPInput.mm
// ---------------------------------------------------------------------------------------------
namespace Input {

/// Registers the "gamepad" ButtonDevice/AnalogDevice factories and the "pp_motion" MotionDevice
/// factory with Input::RegisterFactory. Called once from prepare. Never call InputCommon::Init().
void RegisterFactories();

/// Writes Settings::values.current_input_profile: buttons[i] = "code:<i>,engine:gamepad" for every
/// Settings::NativeButton i (code == PPButton raw value), analogs[i] = "code:<i>,engine:gamepad",
/// motion_device = "engine:pp_motion", touch_device = "engine:emu_window".
void ConfigureInputProfile();

void SetButton(int native_button, bool pressed);
/// x, y in -1...1 (y up); normalised to the unit circle.
void SetAnalog(int native_analog, float x, float y);
/// Releases every button and centres every stick.
void ReleaseAll();
/// CoreMotion device-frame sample (g, rad/s); converted to the 3DS frame (g, deg/s) using the
/// Android rotation index (PPInterfaceOrientation raw value).
void SetMotion(double ax, double ay, double az, double gx, double gy, double gz, int rotation);

} // namespace Input

// ---------------------------------------------------------------------------------------------
// Owner: PPJit.mm
// ---------------------------------------------------------------------------------------------

/// CS_DEBUGGED check + RW->RX mprotect probe on an anonymous page. Never executes the page.
bool IsJITAvailable();

// ---------------------------------------------------------------------------------------------
// Owner: PPApplets.mm
// ---------------------------------------------------------------------------------------------
namespace Applets {

/// Hooks used by the software keyboard to reach the UI. Installed by PPEmulator.mm before boot.
/// Both callbacks are invoked from the emulation thread; the installer is responsible for
/// hopping to the main queue (RunOnMain) before touching UIKit or the delegate.
struct KeyboardPresenter {
    std::function<void(PPKeyboardRequest*)> present;
    std::function<void(NSString*)> show_error;
};
void SetKeyboardPresenter(KeyboardPresenter presenter);

/// Creates the frontend keyboard registered with System::RegisterSoftwareKeyboard after
/// Frontend::RegisterDefaultApplets. Execute() blocks the emulation thread on a semaphore until
/// the PPKeyboardRequest is finished (or cancelled).
std::shared_ptr<Frontend::SoftwareKeyboard> CreateSoftwareKeyboard();

/// Completes any pending keyboard request with the cancel/first button and empty text so a
/// blocked emulation thread can proceed (called by PPEmulator.mm when stopping). Sticky: every
/// later request of the session is cancelled immediately, until ResetKeyboardCancellation().
void CancelPendingKeyboard();

/// Clears the sticky cancellation. Called by the emulation thread at the start of each boot.
void ResetKeyboardCancellation();

} // namespace Applets

// ---------------------------------------------------------------------------------------------
// Owner: PPSystem.mm (console configuration, titles, CIA, save state listing)
// ---------------------------------------------------------------------------------------------
namespace Console {

/// CFG helpers. Only valid while no game is active (callers check IsGameActive()).
/// They use Service::CFG::GetModule(Core::System::GetInstance()), which builds a temporary module
/// from the NAND config save when the system is powered off, and persist with
/// UpdateConfigNANDSavegame() / SaveMacAddress().
NSString* _Nullable GetConsoleUsername();
bool SetConsoleUsername(NSString* name, NSError* _Nullable* _Nullable error);
PPSystemLanguage GetSystemLanguage();
bool SetSystemLanguage(PPSystemLanguage language, NSError* _Nullable* _Nullable error);
bool RegenerateConsoleID(NSError* _Nullable* _Nullable error);
bool RegenerateMACAddress(NSError* _Nullable* _Nullable error);

/// Blocking CIA install (call from a background queue). progress(written, total).
/// Returns nil on success.
NSError* _Nullable InstallCIA(NSString* path, const std::function<void(std::size_t, std::size_t)>& progress);

/// Scans <sdmc>/Nintendo 3DS/000.../000.../title/00040000 and <nand>/000.../title/00040010 for
/// executable contents (Loader::AppLoader::IsExecutable), like the Android frontend.
NSArray<PPGameInfo*>* ScanInstalledTitles();

/// Core::ListSaveStates(title_id, 0) mapped to PPSaveStateInfo.
NSArray<PPSaveStateInfo*>* ListSaveStates(std::uint64_t title_id);

} // namespace Console

} // namespace PlanetPort

// ---------------------------------------------------------------------------------------------
// Private initialisers of the public value classes (owner of each implementation in brackets).
// ---------------------------------------------------------------------------------------------

@interface PPPerformanceStats ()  // [PPEmulator.mm]
- (instancetype)initWithFPS:(double)fps speed:(double)speedPercent frameTime:(double)frameTimeMs;
@end

@interface PPSaveStateInfo ()  // [PPSystem.mm]
- (instancetype)initWithSlot:(NSUInteger)slot date:(nullable NSDate*)date compatible:(BOOL)compatible;
@end

@interface PPGameInfo ()  // [PPGameInfo.mm]
/// Same as +gameInfoAtPath:error: but flags the result as an installed title.
+ (nullable PPGameInfo*)installedGameInfoAtPath:(NSString*)path;
@end

NS_ASSUME_NONNULL_END
