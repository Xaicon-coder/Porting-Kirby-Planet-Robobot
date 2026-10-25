// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Main entry point of the bridge. One shared instance drives Core::System on a dedicated
// emulation thread (boot, run loop, shutdown all happen on that thread).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <PlanetCore/PPTypes.h>
#import <PlanetCore/PPSettings.h>
#import <PlanetCore/PPGameInfo.h>

NS_ASSUME_NONNULL_BEGIN

@class PPEmulator;

#pragma mark - Software keyboard applet

/// A request from the game to show the 3DS software keyboard. Delivered on the main queue through
/// -emulator:requestsKeyboard:. The emulation thread is blocked until -finishWithText:buttonIndex:
/// is called, so the UI must always complete it (also when the game is stopped: the bridge
/// completes pending requests itself on stop).
@interface PPKeyboardRequest : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// Hint text supplied by the game (may be empty).
@property (nonatomic, readonly, copy) NSString *hintText;
/// Maximum number of characters (0 = no limit announced by the game).
@property (nonatomic, readonly) NSUInteger maxLength;
@property (nonatomic, readonly) BOOL multiline;
/// Button titles in game order. The index of a title is the button id to pass back.
/// Contains 1 to 3 entries; empty game strings are replaced by Italian defaults
/// ("Annulla", "Non ricordo", "OK").
@property (nonatomic, readonly, copy) NSArray<NSString *> *buttonTitles;
/// Index in buttonTitles of the confirming button (the only one whose text is validated).
@property (nonatomic, readonly) NSInteger confirmButtonIndex;
/// Validates text with the game's rules (SoftwareKeyboard::ValidateInput). Returns nil when the
/// text is acceptable, otherwise an Italian error message. Thread-safe.
- (nullable NSString *)validateText:(NSString *)text NS_SWIFT_NAME(validateText(_:));
/// Completes the request. Must be called exactly once (later calls are ignored). Any thread.
/// For the confirm button the text should already have passed -validateText:; if it does not,
/// the bridge returns the error through -emulator:keyboardError: and re-sends the request.
- (void)finishWithText:(NSString *)text
           buttonIndex:(NSInteger)buttonIndex NS_SWIFT_NAME(finish(withText:buttonIndex:));
@end

#pragma mark - Small value types

@interface PPPerformanceStats : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// Emulated game frames per second.
@property (nonatomic, readonly) double gameFPS;
/// Emulation speed in percent (100 = full speed).
@property (nonatomic, readonly) double speedPercent;
/// Frame time in milliseconds.
@property (nonatomic, readonly) double frameTimeMs;
@end

@interface PPSaveStateInfo : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// 0 = quick save slot, 1...10 = regular slots.
@property (nonatomic, readonly) NSUInteger slot;
/// Creation time, nil when unknown.
@property (nonatomic, readonly, nullable) NSDate *date;
/// NO when the state was produced by a different core revision/build (cannot be loaded).
@property (nonatomic, readonly) BOOL compatible;
@end

#pragma mark - Delegate

/// Every delegate method is invoked on the main queue.
/// Swift names are pinned with NS_SWIFT_NAME so they never depend on importer heuristics.
@protocol PPEmulatorDelegate <NSObject>
- (void)emulator:(PPEmulator *)emulator
    didChangeState:(PPEmulationState)state NS_SWIFT_NAME(emulator(_:didChange:));
/// Sent once after the emulation thread has fully shut down (state is Idle again).
/// error == nil for a user-requested stop or a game-requested shutdown.
- (void)emulator:(PPEmulator *)emulator
    didStopWithError:(nullable NSError *)error NS_SWIFT_NAME(emulator(_:didStopWithError:));
@optional
/// Non-fatal problems: save state failures, missing system files, JIT requested but unavailable.
- (void)emulator:(PPEmulator *)emulator
    didReportWarning:(NSError *)warning NS_SWIFT_NAME(emulator(_:didReportWarning:));
/// Disk shader cache loading progress (throttled to at most ~10 calls per second).
- (void)emulator:(PPEmulator *)emulator
    shaderLoadStage:(PPShaderLoadStage)stage
           progress:(NSUInteger)progress
              total:(NSUInteger)total
    NS_SWIFT_NAME(emulator(_:shaderLoadStage:progress:total:));
/// The game asks for text input. See PPKeyboardRequest.
- (void)emulator:(PPEmulator *)emulator
    requestsKeyboard:(PPKeyboardRequest *)request NS_SWIFT_NAME(emulator(_:requestsKeyboard:));
/// The game rejected the last keyboard input (SoftwareKeyboard::ShowError).
- (void)emulator:(PPEmulator *)emulator
    keyboardError:(NSString *)message NS_SWIFT_NAME(emulator(_:keyboardError:));
/// A save/load state request finished (success == NO is also reported through didReportWarning:).
- (void)emulator:(PPEmulator *)emulator
    didFinishSaveStateOperation:(BOOL)isLoad
                           slot:(NSUInteger)slot
                        success:(BOOL)success
    NS_SWIFT_NAME(emulator(_:didFinishSaveStateOperation:slot:success:));
@end

#pragma mark - Emulator

@interface PPEmulator : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (class, nonatomic, readonly) PPEmulator *sharedEmulator NS_SWIFT_NAME(shared);

/// YES when executable memory can be created right now (app launched with a debugger attached,
/// e.g. through StikDebug / SideStore "Enable JIT" / Xcode). Evaluated on each access.
@property (class, nonatomic, readonly, getter=isJITAvailable) BOOL JITAvailable;

@property (nonatomic, weak, nullable) id<PPEmulatorDelegate> delegate;

/// Thread-safe snapshot of the current state.
@property (atomic, readonly) PPEmulationState state;

/// The user directory passed to -prepareWithUserDirectory:error: (with trailing "/"), nil before.
@property (nonatomic, readonly, copy, nullable) NSString *userDirectory;

/// Title id of the running game, 0 when idle or unknown.
@property (atomic, readonly) uint64_t runningTitleID;

/// One-time global initialisation. Call on the main thread at app launch, before any other
/// PlanetCore API (PPGameInfo, PPMultiplayer included). Creates the Azahar user folder layout
/// (config, sdmc, nand, sysdata, shaders, states, cheats, log, ...) inside `directory`, starts
/// logging, fills the default Settings::values, registers the input/motion factories and calls
/// Network::Init(). Idempotent: later calls return YES and ignore `directory`.
- (BOOL)prepareWithUserDirectory:(NSString *)directory
                           error:(NSError **)error NS_SWIFT_NAME(prepare(withUserDirectory:));

#pragma mark Lifecycle (main thread)

/// Boots `path` asynchronously on a dedicated emulation thread (8 MB stack).
/// Returns NO with an error only for immediate failures (not prepared, already running, file
/// missing, .cia). Every later failure is reported through -emulator:didStopWithError:.
/// `layer` must stay alive, attached and unchanged until -emulator:didStopWithError: is sent.
/// `drawableSize` is in pixels (points * contentScaleFactor); `portrait` selects the portrait
/// layout family.
- (BOOL)startGameAtPath:(NSString *)path
                  layer:(CAMetalLayer *)layer
           drawableSize:(CGSize)drawableSize
               portrait:(BOOL)portrait
               settings:(PPSettings *)settings
                  error:(NSError **)error
    NS_SWIFT_NAME(startGame(atPath:layer:drawableSize:portrait:settings:));

/// Stops calling RunLoop (audio muted). No-op unless Running.
- (void)pause;
/// No-op unless Paused.
- (void)resume;
/// Asynchronous stop; -emulator:didStopWithError:nil follows. Safe in any state.
- (void)stop;
/// Restarts the running game (Core::System::SendSignal(Signal::Reset)).
- (void)reset;

/// The view (and therefore the layer drawable) changed size or orientation. Pixels.
/// Applied on the emulation thread before the next frame.
- (void)updateDrawableSize:(CGSize)drawableSize
                  portrait:(BOOL)portrait NS_SWIFT_NAME(updateDrawableSize(_:portrait:));

/// Applies runtime-changeable values (frame limit, turbo speed, volume, audio stretching,
/// cpu clock, resolution, layout, portrait layout, swap screens, large screen proportion).
/// Boot-time-only values are stored and used at the next boot. Safe in any state.
- (void)applyRuntimeSettings:(PPSettings *)settings NS_SWIFT_NAME(applyRuntimeSettings(_:));

/// Toggles Settings::is_temporary_frame_limit using the last settings' turboSpeedPercent.
- (void)setFastForwardEnabled:(BOOL)enabled NS_SWIFT_NAME(setFastForwardEnabled(_:));
@property (atomic, readonly, getter=isFastForwardEnabled) BOOL fastForwardEnabled;

#pragma mark Input (any thread, cheap, lock-free or short locks)

- (void)setButton:(PPButton)button
          pressed:(BOOL)pressed NS_SWIFT_NAME(setButton(_:pressed:));
/// x, y in -1...1, y positive = up. Values outside the unit circle are normalised.
- (void)setAnalogStick:(PPAnalogStick)stick
                     x:(float)x
                     y:(float)y NS_SWIFT_NAME(setAnalogStick(_:x:y:));
/// Releases every button, centres both sticks, ends any touch.
- (void)releaseAllInputs;

/// Touch on the render view, in drawable pixels (same space as drawableSize).
/// Returns YES when the point is inside the emulated bottom (touch) screen.
- (BOOL)touchBeganAtPoint:(CGPoint)pixelPoint NS_SWIFT_NAME(touchBegan(at:));
- (void)touchMovedToPoint:(CGPoint)pixelPoint NS_SWIFT_NAME(touchMoved(to:));
- (void)touchEnded;

/// Raw CoreMotion device-frame sample: total acceleration in g (gravity included, CoreMotion
/// sign convention) and rotation rate in rad/s. The bridge rotates it into the 3DS frame
/// according to `orientation` and converts gyro to deg/s.
- (void)updateMotionWithAccelerationX:(double)ax
                                    y:(double)ay
                                    z:(double)az
                        rotationRateX:(double)gx
                                    y:(double)gy
                                    z:(double)gz
                          orientation:(PPInterfaceOrientation)orientation
    NS_SWIFT_NAME(updateMotion(accelerationX:y:z:rotationRateX:y:z:orientation:));

#pragma mark Save states

/// Requests a save into `slot` (0...10). Processed by the emulation thread while Running
/// (a request made while Paused is processed after -resume).
- (void)saveStateToSlot:(NSUInteger)slot NS_SWIFT_NAME(saveState(toSlot:));
- (void)loadStateFromSlot:(NSUInteger)slot NS_SWIFT_NAME(loadState(fromSlot:));
/// Existing states for a title (any thread, prepared required).
- (NSArray<PPSaveStateInfo *> *)saveStatesForTitleID:(uint64_t)titleID
    NS_SWIFT_NAME(saveStates(forTitleID:));

#pragma mark Stats

/// Poll about once per second from the main thread. Zeros unless Running.
- (PPPerformanceStats *)performanceStats;

#pragma mark Console configuration (only while Idle; otherwise fail with PPErrorCodeBusy / NO)

/// The emulated console user name (CFG). Also used as multiplayer nickname. nil if unreadable.
- (nullable NSString *)consoleUsername;
/// 1...10 UTF-16 code units. Persisted to the emulated NAND config save.
- (BOOL)setConsoleUsername:(NSString *)name
                     error:(NSError **)error NS_SWIFT_NAME(setConsoleUsername(_:));
- (PPSystemLanguage)systemLanguage;
- (BOOL)setSystemLanguage:(PPSystemLanguage)language
                    error:(NSError **)error NS_SWIFT_NAME(setSystemLanguage(_:));
/// Generates and persists a new console unique id (fixes multiplayer ConsoleIdCollision).
- (BOOL)regenerateConsoleIDWithError:(NSError **)error NS_SWIFT_NAME(regenerateConsoleID());
/// Generates and persists a new console MAC address (fixes multiplayer MacCollision).
- (BOOL)regenerateMACAddressWithError:(NSError **)error NS_SWIFT_NAME(regenerateMACAddress());

#pragma mark Installed titles

/// Installs a decrypted .cia into the emulated SD card on a background queue.
/// `progress` (0...1) and `completion` run on the main queue. Only while Idle.
- (void)installCIAAtPath:(NSString *)path
                progress:(nullable void (^)(double fraction))progress
              completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(installCIA(atPath:progress:completion:));

/// Bootable application titles installed in the emulated SD card / NAND
/// (each PPGameInfo.path is the executable content .app to pass to -startGameAtPath:...).
/// Slow-ish (disk scan): call off the main thread.
- (NSArray<PPGameInfo *> *)installedTitles;

@end

NS_ASSUME_NONNULL_END
