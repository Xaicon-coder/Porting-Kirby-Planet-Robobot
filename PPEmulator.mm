// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// PPEmulator: owns the emulation thread. Mirrors the Android frontend's RunCitra()
// (src/android/app/src/main/jni/native.cpp) adapted to iOS (CAMetalLayer, NSThread, GCD).

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <ctime>
#include <exception>
#include <memory>
#include <mutex>
#include <string>

#include "common/apple_authorization.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/filter.h"
#include "common/logging/log.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/applets/swkbd.h"
#include "core/loader/loader.h"
#include "core/perf_stats.h"
#include "core/savestate.h"
#include "network/network.h"
#include "video_core/gpu.h"
#include "video_core/rasterizer_interface.h"
#include "video_core/renderer_base.h"

#import <QuartzCore/QuartzCore.h>

#import "PPEmuWindow.h"
#import "PPInternal.h"

@interface PPEmulator ()
/// Main thread: the emulation thread of `session` has finished.
- (void)pp_sessionDidEnd:(void*)session;
@end

// -------------------------------------------------------------------------------------------
// PPPerformanceStats
// -------------------------------------------------------------------------------------------

@implementation PPPerformanceStats

- (instancetype)initWithFPS:(double)fps speed:(double)speedPercent frameTime:(double)frameTimeMs {
    if ((self = [super init])) {
        _gameFPS = fps;
        _speedPercent = speedPercent;
        _frameTimeMs = frameTimeMs;
    }
    return self;
}

@end

// -------------------------------------------------------------------------------------------
// Global state shared with the rest of the bridge
// -------------------------------------------------------------------------------------------

namespace PlanetPort {

namespace {

std::atomic_bool g_prepared{false};
std::string g_user_directory;
std::atomic<int> g_state{static_cast<int>(PPEmulationStateIdle)};
std::atomic<std::uint64_t> g_running_title_id{0};
/// Set when System::Load threw: the core may be half initialised, a restart of the app is safer.
std::atomic_bool g_core_poisoned{false};
/// Held by the emulation thread around System::Load and System::Shutdown; the main thread only
/// try_locks it to read performance statistics.
std::mutex g_core_lifecycle_mutex;

enum class SaveStateOp : int { None = 0, Save = 1, Load = 2 };

/// Everything one boot needs. Shared between the main thread and the emulation thread.
struct EmuSession {
    // Immutable after start.
    std::string path;
    CAMetalLayer* layer = nil;
    PPSettings* boot_settings = nil;

    // Initial layout (used when the window is created), guarded by window_access.
    unsigned width = 1;
    unsigned height = 1;
    bool portrait = false;

    // Control flags.
    std::atomic_bool stop{false};
    std::atomic_bool pause{false};
    std::atomic_bool work_pending{false};
    std::atomic_bool settings_dirty{false};
    std::mutex mutex; // guards cv waits and pending_settings
    std::condition_variable cv;
    PPSettings* pending_settings = nil;

    // Window, created/destroyed by the emulation thread, used by the main thread for touch and
    // layout under window_access.
    std::mutex window_access;
    std::unique_ptr<PPEmuWindow> window;

    // Save states. The plain fields are written by the main thread only while ss_op == None and
    // published by the (sequentially consistent) store to ss_op; afterwards only the emulation
    // thread touches them until it resets ss_op.
    std::atomic<int> ss_op{static_cast<int>(SaveStateOp::None)};
    std::atomic<std::uint32_t> ss_slot{0};
    std::atomic<std::int64_t> ss_wall_time{0}; // seconds since epoch
    std::chrono::steady_clock::time_point ss_request_time{};
    std::atomic<std::uint64_t> init_done_count{0};
    std::uint64_t ss_init_count_at_request = 0;
    std::chrono::steady_clock::time_point ss_last_check{};

    // Misc.
    std::atomic_bool ss_signal_sent{false};
    std::atomic_bool reset_requested{false};

    // Fast-forward (re-applied after System::Load / Reset, which clear it).
    std::atomic_bool fast_forward{false};
    std::atomic<double> turbo_speed{200.0};

    // Performance snapshot, sampled by the emulation thread (the core's PerfStats object is
    // destroyed and recreated by Reset / LoadState, so the main thread never touches it).
    std::mutex stats_mutex;
    Core::PerfStats::Results stats{};
    std::chrono::steady_clock::time_point stats_time{};

    // Misc.
    std::atomic<std::uint64_t> title_id{0};
    float user_volume = 1.0f; // emulation thread only
    bool warned_system_files = false;

    void Notify() {
        {
            std::scoped_lock lock{mutex};
            work_pending = true;
        }
        cv.notify_all();
    }
};

PPEmulationState CurrentState() {
    return static_cast<PPEmulationState>(g_state.load());
}

void SetState(PPEmulationState state) {
    const int previous = g_state.exchange(static_cast<int>(state));
    if (previous == static_cast<int>(state)) {
        return;
    }
    RunOnMain(^{
        PPEmulator* emulator = PPEmulator.sharedEmulator;
        id<PPEmulatorDelegate> delegate = emulator.delegate;
        // Coalesce: report the state that is current when the block runs.
        if (static_cast<int>(state) != g_state.load()) {
            return;
        }
        [delegate emulator:emulator didChangeState:state];
    });
}

void ReportWarning(NSError* warning) {
    if (warning == nil) {
        return;
    }
    RunOnMain(^{
        PPEmulator* emulator = PPEmulator.sharedEmulator;
        id<PPEmulatorDelegate> delegate = emulator.delegate;
        if ([delegate respondsToSelector:@selector(emulator:didReportWarning:)]) {
            [delegate emulator:emulator didReportWarning:warning];
        }
    });
}

void ReportSaveStateResult(bool is_load, std::uint32_t slot, bool success) {
    RunOnMain(^{
        PPEmulator* emulator = PPEmulator.sharedEmulator;
        id<PPEmulatorDelegate> delegate = emulator.delegate;
        if ([delegate respondsToSelector:@selector(emulator:didFinishSaveStateOperation:slot:success:)]) {
            [delegate emulator:emulator
                didFinishSaveStateOperation:is_load
                                       slot:slot
                                    success:success];
        }
    });
}

NSError* ErrorForStatus(Core::System::ResultStatus status, const std::string& details) {
    using RS = Core::System::ResultStatus;
    switch (status) {
    case RS::ErrorNotInitialized:
        return MakeError(PPErrorCodeLoaderFailed, @"Il sistema emulato non è stato inizializzato.",
                         details);
    case RS::ErrorGetLoader:
        return MakeError(PPErrorCodeUnsupportedFormat,
                         @"Formato del file non riconosciuto. Usa un dump .3ds, .cci, .cxi o "
                         @"installa il file .cia.",
                         details);
    case RS::ErrorSystemMode:
        return MakeError(PPErrorCodeSystemMode,
                         @"Impossibile determinare la modalità di sistema del gioco. Il file "
                         @"potrebbe essere danneggiato.",
                         details);
    case RS::ErrorLoader:
        return MakeError(PPErrorCodeLoaderFailed, @"Caricamento del gioco non riuscito.", details);
    case RS::ErrorLoader_ErrorEncrypted:
        return MakeError(PPErrorCodeEncryptedROM,
                         @"Il gioco è criptato. Azahar avvia solo dump decriptati: rifai il dump "
                         @"con GodMode9 e scegli \"Decrypt file\" (oppure \"Build CIA from "
                         @"file\") prima di importarlo.",
                         details);
    case RS::ErrorLoader_ErrorInvalidFormat:
        return MakeError(PPErrorCodeUnsupportedFormat,
                         @"Il file non è un gioco 3DS valido o è danneggiato.", details);
    case RS::ErrorLoader_ErrorGbaTitle:
        return MakeError(PPErrorCodeGBAVirtualConsole,
                         @"I titoli Virtual Console per Game Boy Advance non sono supportati.",
                         details);
    case RS::ErrorLoader_ErrorPatches:
    case RS::ErrorLoader_ErrorPatchesInvalidTitle:
        return MakeError(PPErrorCodeLoaderFailed,
                         @"Le patch del gioco non sono valide per questo titolo.", details);
    case RS::ErrorSystemFiles:
        return MakeError(PPErrorCodeSystemFilesMissing,
                         @"Mancano alcuni file di sistema richiesti dal gioco (ad esempio i font "
                         @"condivisi). Il gioco potrebbe non funzionare correttamente.",
                         details);
    case RS::ErrorSavestate:
        return MakeError(PPErrorCodeSaveStateFailed,
                         @"Operazione sul salvataggio rapido non riuscita.", details);
    case RS::ErrorSavestateBuildMismatch:
        return MakeError(PPErrorCodeSaveStateFailed,
                         @"Questo salvataggio rapido è stato creato da un'altra versione del core "
                         @"e non può essere caricato.",
                         details);
    case RS::ErrorArticDisconnected:
        return MakeError(PPErrorCodeLoaderFailed, @"Connessione Artic Base interrotta.", details);
    case RS::ErrorN3DSApplication:
        return MakeError(PPErrorCodeNew3DSRequired,
                         @"Questo gioco richiede New Nintendo 3DS: attiva \"Modalità New 3DS\" "
                         @"nelle impostazioni.",
                         details);
    case RS::ErrorCoreExceptionRaised:
        return MakeError(PPErrorCodeCoreException,
                         @"Il gioco ha generato un'eccezione della CPU emulata e si è fermato.",
                         details);
    case RS::ErrorShaderCacheCrash:
        return MakeError(PPErrorCodeShaderCacheCrash,
                         @"La cache degli shader su disco è danneggiata. Disattiva la cache degli "
                         @"shader o eliminala dalla cartella shaders.",
                         details);
    case RS::ShutdownRequested:
    case RS::Success:
        return nil;
    case RS::ErrorUnknown:
    default:
        return MakeError(PPErrorCodeUnknown, @"Errore sconosciuto del core di emulazione.",
                         details);
    }
}

bool IsCIAPath(const std::string& path) {
    const auto dot = path.find_last_of('.');
    if (dot == std::string::npos) {
        return false;
    }
    std::string ext = path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return ext == "cia" || ext == "zcia" || ext == "bcia";
}

std::int64_t NowSeconds() {
    return static_cast<std::int64_t>(std::time(nullptr));
}

/// Emulation thread: applies pending layout/settings work.
void ProcessPendingWork(EmuSession& s, Core::System& system, bool paused) {
    if (!s.work_pending.exchange(false)) {
        return;
    }
    if (s.window) {
        s.window->ApplyPendingLayout();
    }
    if (s.settings_dirty.exchange(false)) {
        PPSettings* settings = nil;
        {
            std::scoped_lock lock{s.mutex};
            settings = s.pending_settings;
        }
        if (settings != nil) {
            ApplyRuntimeSettingsToValues(settings);
            s.user_volume = Settings::values.volume.GetValue();
            if (paused) {
                Settings::values.volume = 0.0f;
            }
            if (system.IsPoweredOn()) {
                // On non-Android builds ApplySettings re-lays out with portrait = false: do it
                // under the window lock and immediately restore the real layout, so touches on
                // the main thread never see the transient one.
                if (s.window) {
                    s.window->ApplyCoreSettings(system);
                } else {
                    system.ApplySettings();
                }
            }
        }
    }
}

/// Emulation thread: completes a pending save/load state request when possible.
void CheckSaveStateCompletion(EmuSession& s) {
    const auto op = static_cast<SaveStateOp>(s.ss_op.load());
    if (op == SaveStateOp::None) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (now - s.ss_last_check < std::chrono::milliseconds(100)) {
        return;
    }
    s.ss_last_check = now;
    const std::uint32_t slot = s.ss_slot.load();

    bool done = false;
    if (op == SaveStateOp::Save) {
        const auto info = Core::GetSaveStateInfo(s.title_id.load(), 0, slot);
        if (info.slot == slot && static_cast<std::int64_t>(info.time) >= s.ss_wall_time.load() - 1) {
            done = true;
        }
    } else {
        // A successful load re-runs System::Init, which fires the init callback.
        if (s.init_done_count.load() > s.ss_init_count_at_request) {
            done = true;
        }
    }

    if (done) {
        s.ss_op = static_cast<int>(SaveStateOp::None);
        ReportSaveStateResult(op == SaveStateOp::Load, slot, true);
        return;
    }
    if (now - s.ss_request_time > std::chrono::seconds(7)) {
        // The core gives up after 5 s with ErrorSavestate; without an error a load that did not
        // re-init or a save that did not write a file is treated as failed.
        s.ss_op = static_cast<int>(SaveStateOp::None);
        ReportSaveStateResult(op == SaveStateOp::Load, slot, false);
        ReportWarning(MakeError(PPErrorCodeSaveStateFailed,
                                @"Il salvataggio rapido non è stato completato in tempo."));
    }
}

void FailPendingSaveState(EmuSession& s) {
    const auto op = static_cast<SaveStateOp>(s.ss_op.exchange(static_cast<int>(SaveStateOp::None)));
    if (op != SaveStateOp::None) {
        ReportSaveStateResult(op == SaveStateOp::Load, s.ss_slot.load(), false);
    }
}

/// Emulation thread: restores the fast-forward state after System::Load / Reset cleared it.
void ApplyFastForward(EmuSession& s) {
    if (s.fast_forward.load()) {
        Settings::temporary_frame_limit = s.turbo_speed.load();
        Settings::is_temporary_frame_limit = true;
    }
}

/// Emulation thread: refreshes the performance snapshot about once per second.
void SampleStats(EmuSession& s, Core::System& system) {
    const auto now = std::chrono::steady_clock::now();
    if (now - s.stats_time < std::chrono::seconds(1)) {
        return;
    }
    s.stats_time = now;
    const auto results = system.GetAndResetPerfStats();
    std::scoped_lock lock{s.stats_mutex};
    s.stats = results;
}

/// One iteration of the emulation loop. Returns true when the loop must end.
bool RunLoopIteration(EmuSession& s, Core::System& system, bool& paused,
                      NSError* __strong& stop_error) {
    ProcessPendingWork(s, system, paused);

    if (s.pause) {
        if (!paused) {
            paused = true;
            s.user_volume = Settings::values.volume.GetValue();
            Settings::values.volume = 0.0f;
            SetState(PPEmulationStatePaused);
        }
        std::unique_lock lock{s.mutex};
        s.cv.wait(lock, [&s] { return !s.pause || s.stop || s.work_pending; });
        return false;
    }
    if (paused) {
        paused = false;
        Settings::values.volume = s.user_volume;
        SetState(PPEmulationStateRunning);
    }

    // Core signals are only ever sent from this thread, immediately before the RunLoop that
    // consumes them, so a request can never outlive the session and fire on the next boot.
    const bool reset_sent = s.reset_requested.exchange(false) &&
                            system.SendSignal(Core::System::Signal::Reset);
    const auto op = static_cast<SaveStateOp>(s.ss_op.load());
    if (op != SaveStateOp::None && !s.ss_signal_sent.exchange(true)) {
        s.ss_request_time = std::chrono::steady_clock::now();
        const bool sent = system.SendSignal(op == SaveStateOp::Load ? Core::System::Signal::Load
                                                                    : Core::System::Signal::Save,
                                            s.ss_slot.load());
        if (!sent) {
            FailPendingSaveState(s);
            ReportWarning(MakeError(PPErrorCodeSaveStateFailed,
                                    @"Il core è occupato: riprova tra un istante."));
        }
    }

    const auto result = system.RunLoop();
    if (reset_sent) {
        ApplyFastForward(s);
    }

    using RS = Core::System::ResultStatus;
    if (result == RS::Success) {
        CheckSaveStateCompletion(s);
        SampleStats(s, system);
        return false;
    }
    if (result == RS::ShutdownRequested) {
        LOG_INFO(Frontend, "PlanetPort: the game requested a shutdown");
        return true;
    }
    if (result == RS::ErrorSavestate || result == RS::ErrorSavestateBuildMismatch) {
        FailPendingSaveState(s);
        ReportWarning(ErrorForStatus(result, system.GetStatusDetails()));
        return false;
    }
    if (result == RS::ErrorSystemFiles) {
        if (!s.warned_system_files) {
            s.warned_system_files = true;
            ReportWarning(ErrorForStatus(result, system.GetStatusDetails()));
        }
        return false;
    }
    stop_error = ErrorForStatus(result, system.GetStatusDetails());
    return true;
}

/// Body of the emulation thread.
void EmulationThreadMain(std::shared_ptr<EmuSession> session) {
    EmuSession& s = *session;
    Core::System& system = Core::System::GetInstance();
    NSError* stop_error = nil;
    bool loaded = false;

    LOG_INFO(Frontend, "PlanetPort: booting {}", s.path);

    do {
        // 1. Identify the game.
        FileUtil::SetCurrentRomPath(s.path);
        std::unique_ptr<Loader::AppLoader> loader = Loader::GetLoader(s.path);
        if (!loader) {
            stop_error = ErrorForStatus(Core::System::ResultStatus::ErrorGetLoader, "");
            break;
        }
        u64 program_id = 0;
        loader->ReadProgramId(program_id);
        s.title_id = program_id;
        g_running_title_id = program_id;

        // 2. CPU backend.
        bool use_jit = false;
        switch (s.boot_settings.cpuBackend) {
        case PPCPUBackendInterpreter:
            use_jit = false;
            break;
        case PPCPUBackendJIT:
            use_jit = IsJITAvailable();
            if (!use_jit) {
                ReportWarning(MakeError(
                    PPErrorCodeInvalidArgument,
                    @"Il JIT è stato richiesto ma non è disponibile: avvia l'app con un debugger "
                    @"collegato (ad esempio StikDebug). Viene usato l'interprete."));
            }
            break;
        case PPCPUBackendAuto:
        default:
            use_jit = IsJITAvailable();
            break;
        }
        LOG_INFO(Frontend, "PlanetPort: CPU backend = {}", use_jit ? "JIT" : "interpreter");

        // 3. Settings.
        ApplyBootSettings(s.boot_settings, use_jit);
        s.user_volume = Settings::values.volume.GetValue();
        PlanetPort::Input::ConfigureInputProfile();
        system.ApplySettings();
        Settings::LogSettings();

        // 4. Frontend applets and permissions.
        PlanetPort::Applets::ResetKeyboardCancellation();
        Frontend::RegisterDefaultApplets(system);
        system.RegisterSoftwareKeyboard(PlanetPort::Applets::CreateSoftwareKeyboard());
        if (s.boot_settings.microphoneEnabled) {
            system.RegisterMicPermissionCheck(
                [] { return AppleAuthorization::CheckAuthorizationForMicrophone(); });
        }
        std::weak_ptr<EmuSession> weak_session = session;
        system.RegisterOnInitCallback([weak_session](bool starting) {
            if (starting) {
                return;
            }
            if (auto locked = weak_session.lock()) {
                locked->init_done_count.fetch_add(1);
            }
        });

        // 5. Render window.
        {
            std::scoped_lock lock{s.window_access};
            s.window = std::make_unique<PPEmuWindow>(s.layer, s.width, s.height, s.portrait);
        }
        s.window->MakeCurrent();

        if (s.stop) {
            break;
        }

        // 6. Boot.
        Core::System::ResultStatus load_result = Core::System::ResultStatus::ErrorUnknown;
        {
            std::scoped_lock lifecycle{g_core_lifecycle_mutex};
            system.RegisterAppLoaderEarly(loader);
            try {
                load_result = system.Load(*s.window, s.path);
            } catch (const std::exception& e) {
                LOG_CRITICAL(Frontend, "PlanetPort: System::Load threw: {}", e.what());
                g_core_poisoned = true;
                stop_error = MakeError(
                    PPErrorCodeGraphicsInitFailed,
                    @"Impossibile inizializzare la grafica (Vulkan/MoltenVK). Riavvia l'app; se "
                    @"il problema persiste il dispositivo potrebbe non essere supportato.",
                    e.what());
                try {
                    system.Shutdown();
                } catch (...) {
                }
                break;
            }
        }
        if (load_result != Core::System::ResultStatus::Success) {
            stop_error = ErrorForStatus(load_result, system.GetStatusDetails());
            break;
        }
        loaded = true;

        // 7. Disk shader cache.
        if (!s.stop) {
            SetState(PPEmulationStateLoadingShaders);
            system.GPU().ApplyPerProgramSettings(program_id);
            auto last_report = std::make_shared<std::chrono::steady_clock::time_point>();
            system.GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(
                s.stop, [last_report](VideoCore::LoadCallbackStage stage, std::size_t value,
                                      std::size_t total, const std::string&) {
                    const auto now = std::chrono::steady_clock::now();
                    const bool complete = stage == VideoCore::LoadCallbackStage::Complete;
                    if (!complete && now - *last_report < std::chrono::milliseconds(100)) {
                        return;
                    }
                    *last_report = now;
                    const auto pp_stage = static_cast<PPShaderLoadStage>(stage);
                    const NSUInteger progress = value;
                    const NSUInteger count = total;
                    RunOnMain(^{
                        PPEmulator* emulator = PPEmulator.sharedEmulator;
                        id<PPEmulatorDelegate> delegate = emulator.delegate;
                        if ([delegate respondsToSelector:@selector(emulator:shaderLoadStage:progress:total:)]) {
                            [delegate emulator:emulator
                                shaderLoadStage:pp_stage
                                       progress:progress
                                          total:count];
                        }
                    });
                });
        }

        // 8. Main loop.
        system.RegisterCoreLoopThreadId();
        bool paused = false;
        if (!s.stop) {
            // System::Load resets the temporary frame limit: re-apply a fast-forward toggled
            // while booting.
            ApplyFastForward(s);
            SetState(s.pause ? PPEmulationStatePaused : PPEmulationStateRunning);
        }
        bool exit_loop = false;
        while (!s.stop && !exit_loop) {
            // Objective-C objects created on this thread (events, keyboard requests, errors)
            // must not pile up for the whole session.
            @autoreleasepool {
                exit_loop = RunLoopIteration(s, system, paused, stop_error);
            }
        }
        if (paused) {
            Settings::values.volume = s.user_volume;
        }
    } while (false);

    // 9. Shutdown (same thread that created the renderer).
    SetState(PPEmulationStateStopping);
    FailPendingSaveState(s);
    PlanetPort::Applets::CancelPendingKeyboard();
    if (loaded || system.IsPoweredOn()) {
        std::scoped_lock lifecycle{g_core_lifecycle_mutex};
        if (s.window) {
            s.window->DoneCurrent();
        }
        system.Shutdown();
    }
    {
        std::scoped_lock lock{s.window_access};
        s.window.reset();
    }
    system.RegisterOnInitCallback([](bool) {});
    Settings::ResetTemporaryFrameLimit();
    PlanetPort::Input::ReleaseAll();
    g_running_title_id = 0;
    LOG_INFO(Frontend, "PlanetPort: emulation stopped");

    // Idle must be the very last state change: a new boot may start right after it.
    g_state = static_cast<int>(PPEmulationStateIdle);
    RunOnMain(^{
        PPEmulator* emulator = PPEmulator.sharedEmulator;
        [emulator pp_sessionDidEnd:session.get()];
        id<PPEmulatorDelegate> delegate = emulator.delegate;
        [delegate emulator:emulator didChangeState:PPEmulationStateIdle];
        [delegate emulator:emulator didStopWithError:stop_error];
    });
}

} // namespace

bool IsPrepared() {
    return g_prepared.load();
}

const std::string& UserDirectory() {
    return g_user_directory;
}

bool IsGameActive() {
    return g_state.load() != static_cast<int>(PPEmulationStateIdle);
}

} // namespace PlanetPort

// -------------------------------------------------------------------------------------------
// PPEmulator
// -------------------------------------------------------------------------------------------

using namespace PlanetPort;

@implementation PPEmulator {
    std::mutex _sessionMutex;
    std::shared_ptr<EmuSession> _session; // guarded by _sessionMutex
    PPSettings* _lastSettings;            // main thread only
    std::atomic_bool _fastForward;
    NSString* _userDirectory;
}

- (std::shared_ptr<EmuSession>)currentSession {
    std::scoped_lock lock{_sessionMutex};
    return _session;
}

+ (PPEmulator*)sharedEmulator {
    static PPEmulator* shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[PPEmulator alloc] initPrivate];
    });
    return shared;
}

+ (BOOL)isJITAvailable {
    return PlanetPort::IsJITAvailable() ? YES : NO;
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _fastForward = false;
        _lastSettings = [PPSettings defaultSettings];
    }
    return self;
}

- (PPEmulationState)state {
    return CurrentState();
}

- (uint64_t)runningTitleID {
    return g_running_title_id.load();
}

- (NSString*)userDirectory {
    return _userDirectory;
}

- (BOOL)isFastForwardEnabled {
    return _fastForward.load() ? YES : NO;
}

#pragma mark Prepare

- (BOOL)prepareWithUserDirectory:(NSString*)directory error:(NSError**)error {
    if (g_prepared.load()) {
        return YES;
    }
    if (directory.length == 0) {
        if (error) {
            *error = MakeError(PPErrorCodeInvalidArgument, @"Cartella utente non valida.");
        }
        return NO;
    }

    NSString* standardized = directory.stringByStandardizingPath;
    NSError* fsError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:standardized
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&fsError]) {
        if (error) {
            *error = MakeError(PPErrorCodeNotPrepared,
                               [NSString stringWithFormat:@"Impossibile creare la cartella "
                                                          @"utente: %@",
                                                          fsError.localizedDescription]);
        }
        return NO;
    }

    std::string dir = ToStdString(standardized);
    if (dir.empty() || dir.back() != '/') {
        dir.push_back('/');
    }

    // Must run before anything calls FileUtil::GetUserPath (logging, keys, config).
    FileUtil::SetUserPath(dir);
    using FileUtil::UserPath;
    for (const UserPath path :
         {UserPath::ConfigDir, UserPath::CacheDir, UserPath::SDMCDir, UserPath::NANDDir,
          UserPath::SysDataDir, UserPath::LogDir, UserPath::CheatsDir, UserPath::ShaderDir,
          UserPath::DumpDir, UserPath::LoadDir, UserPath::StatesDir, UserPath::IconsDir,
          UserPath::DLLDir}) {
        FileUtil::CreateFullPath(FileUtil::GetUserPath(path));
    }

    ApplyGlobalDefaults();

    Common::Log::Initialize();
    Common::Log::Start();
#ifndef NDEBUG
    Common::Log::SetColorConsoleBackendEnabled(true);
#endif
    {
        Common::Log::Filter filter;
        filter.ParseFilterString(Settings::values.log_filter.GetValue());
        Common::Log::SetGlobalFilter(filter);
    }

    PlanetPort::Input::RegisterFactories();

    PlanetPort::Applets::KeyboardPresenter presenter;
    presenter.present = [](PPKeyboardRequest* request) {
        RunOnMain(^{
            PPEmulator* emulator = PPEmulator.sharedEmulator;
            id<PPEmulatorDelegate> delegate = emulator.delegate;
            if ([delegate respondsToSelector:@selector(emulator:requestsKeyboard:)]) {
                [delegate emulator:emulator requestsKeyboard:request];
            } else {
                // No keyboard UI: cancel (never re-presented, unlike an empty confirm that the
                // game could reject forever).
                PlanetPort::Applets::CancelPendingKeyboard();
            }
        });
    };
    presenter.show_error = [](NSString* message) {
        RunOnMain(^{
            PPEmulator* emulator = PPEmulator.sharedEmulator;
            id<PPEmulatorDelegate> delegate = emulator.delegate;
            if ([delegate respondsToSelector:@selector(emulator:keyboardError:)]) {
                [delegate emulator:emulator keyboardError:message];
            }
        });
    };
    PlanetPort::Applets::SetKeyboardPresenter(std::move(presenter));

    if (!Network::Init()) {
        LOG_ERROR(Frontend, "PlanetPort: Network::Init failed, multiplayer unavailable");
    }

    g_user_directory = dir;
    _userDirectory = ToNSString(dir);
    g_prepared = true;
    LOG_INFO(Frontend, "PlanetPort: user directory {}", dir);
    return YES;
}

#pragma mark Lifecycle

- (BOOL)startGameAtPath:(NSString*)path
                  layer:(CAMetalLayer*)layer
           drawableSize:(CGSize)drawableSize
               portrait:(BOOL)portrait
               settings:(PPSettings*)settings
                  error:(NSError**)error {
    auto fail = [error](PPErrorCode code, NSString* message) {
        if (error) {
            *error = MakeError(code, message);
        }
        return NO;
    };

    if (!g_prepared.load()) {
        return fail(PPErrorCodeNotPrepared, @"Il core non è stato inizializzato.");
    }
    if (g_core_poisoned.load()) {
        return fail(PPErrorCodeGraphicsInitFailed,
                    @"Il core è in uno stato non valido dopo un errore grafico. Chiudi e riapri "
                    @"l'app.");
    }
    if (CurrentState() != PPEmulationStateIdle || [self currentSession]) {
        return fail(PPErrorCodeAlreadyRunning, @"Un gioco è già in esecuzione.");
    }
    if (layer == nil) {
        return fail(PPErrorCodeInvalidArgument, @"Superficie di rendering non valida.");
    }
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return fail(PPErrorCodeFileNotFound, @"Il file del gioco non esiste più.");
    }
    const std::string std_path = ToStdString(path);
    if (IsCIAPath(std_path)) {
        return fail(PPErrorCodeCIANeedsInstall,
                    @"I file .cia vanno prima installati: usa \"Importa\" e poi avvia il gioco "
                    @"installato.");
    }

    auto session = std::make_shared<EmuSession>();
    session->path = std_path;
    session->layer = layer;
    session->boot_settings = [(settings ?: [PPSettings defaultSettings]) copy];
    session->width = static_cast<unsigned>(std::max<CGFloat>(1.0, std::round(drawableSize.width)));
    session->height =
        static_cast<unsigned>(std::max<CGFloat>(1.0, std::round(drawableSize.height)));
    session->portrait = portrait;

    {
        std::scoped_lock lock{_sessionMutex};
        _session = session;
    }
    _lastSettings = [session->boot_settings copy];
    _fastForward = false;
    Settings::ResetTemporaryFrameLimit();
    session->turbo_speed =
        static_cast<double>(std::clamp<NSInteger>(_lastSettings.turboSpeedPercent, 0, 1000));

    g_state = static_cast<int>(PPEmulationStateBooting);
    [self.delegate emulator:self didChangeState:PPEmulationStateBooting];

    NSThread* thread = [[NSThread alloc] initWithBlock:^{
        EmulationThreadMain(session);
    }];
    thread.name = @"PlanetPort.Emulation";
    thread.stackSize = 8 * 1024 * 1024;
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
    return YES;
}

- (void)pp_sessionDidEnd:(void*)session {
    {
        std::scoped_lock lock{_sessionMutex};
        if (_session.get() == session) {
            _session.reset();
        }
    }
    _fastForward = false;
}

- (void)pause {
    auto session = [self currentSession];
    if (!session || session->stop) {
        return;
    }
    {
        std::scoped_lock lock{session->mutex};
        session->pause = true;
    }
    session->cv.notify_all();
}

- (void)resume {
    auto session = [self currentSession];
    if (!session) {
        return;
    }
    {
        std::scoped_lock lock{session->mutex};
        session->pause = false;
    }
    session->cv.notify_all();
}

- (void)stop {
    auto session = [self currentSession];
    if (!session) {
        return;
    }
    {
        std::scoped_lock lock{session->mutex};
        session->stop = true;
        session->pause = false;
    }
    PlanetPort::Applets::CancelPendingKeyboard();
    Core::System::GetInstance().frame_limiter.SetFrameAdvancing(false);
    session->cv.notify_all();
}

- (void)reset {
    auto session = [self currentSession];
    if (!session || session->stop || CurrentState() == PPEmulationStateIdle) {
        return;
    }
    // Sent to the core by the emulation thread right before its next RunLoop.
    session->reset_requested = true;
    session->Notify();
    [self resume];
}

- (void)updateDrawableSize:(CGSize)drawableSize portrait:(BOOL)portrait {
    auto session = [self currentSession];
    if (!session) {
        return;
    }
    const unsigned width =
        static_cast<unsigned>(std::max<CGFloat>(1.0, std::round(drawableSize.width)));
    const unsigned height =
        static_cast<unsigned>(std::max<CGFloat>(1.0, std::round(drawableSize.height)));
    {
        std::scoped_lock lock{session->window_access};
        if (session->window) {
            session->window->SetPendingLayout(width, height, portrait);
        } else {
            session->width = width;
            session->height = height;
            session->portrait = portrait;
        }
    }
    session->Notify();
}

- (void)applyRuntimeSettings:(PPSettings*)settings {
    if (settings == nil) {
        return;
    }
    _lastSettings = [settings copy];
    const double turbo =
        static_cast<double>(std::clamp<NSInteger>(settings.turboSpeedPercent, 0, 1000));
    if (_fastForward.load()) {
        Settings::temporary_frame_limit = turbo;
    }
    auto session = [self currentSession];
    if (!session) {
        return;
    }
    session->turbo_speed = turbo;
    {
        std::scoped_lock lock{session->mutex};
        session->pending_settings = [settings copy];
        session->settings_dirty = true;
        session->work_pending = true;
    }
    session->cv.notify_all();
}

- (void)setFastForwardEnabled:(BOOL)enabled {
    _fastForward = enabled ? true : false;
    const double turbo =
        static_cast<double>(std::clamp<NSInteger>(_lastSettings.turboSpeedPercent, 0, 1000));
    if (auto session = [self currentSession]) {
        session->turbo_speed = turbo;
        session->fast_forward = enabled ? true : false;
    }
    if (enabled) {
        Settings::temporary_frame_limit = turbo;
        Settings::is_temporary_frame_limit = true;
    } else {
        Settings::is_temporary_frame_limit = false;
    }
}

#pragma mark Input

- (void)setButton:(PPButton)button pressed:(BOOL)pressed {
    PlanetPort::Input::SetButton(static_cast<int>(button), pressed);
}

- (void)setAnalogStick:(PPAnalogStick)stick x:(float)x y:(float)y {
    PlanetPort::Input::SetAnalog(static_cast<int>(stick), x, y);
}

- (void)releaseAllInputs {
    PlanetPort::Input::ReleaseAll();
    [self touchEnded];
}

- (BOOL)touchBeganAtPoint:(CGPoint)pixelPoint {
    auto session = [self currentSession];
    if (!session) {
        return NO;
    }
    const unsigned x = static_cast<unsigned>(std::max<CGFloat>(0.0, pixelPoint.x + 0.5));
    const unsigned y = static_cast<unsigned>(std::max<CGFloat>(0.0, pixelPoint.y + 0.5));
    std::scoped_lock lock{session->window_access};
    return session->window && session->window->TouchBegan(x, y) ? YES : NO;
}

- (void)touchMovedToPoint:(CGPoint)pixelPoint {
    auto session = [self currentSession];
    if (!session) {
        return;
    }
    const unsigned x = static_cast<unsigned>(std::max<CGFloat>(0.0, pixelPoint.x + 0.5));
    const unsigned y = static_cast<unsigned>(std::max<CGFloat>(0.0, pixelPoint.y + 0.5));
    std::scoped_lock lock{session->window_access};
    if (session->window) {
        session->window->TouchMovedTo(x, y);
    }
}

- (void)touchEnded {
    auto session = [self currentSession];
    if (!session) {
        return;
    }
    std::scoped_lock lock{session->window_access};
    if (session->window) {
        session->window->TouchEnded();
    }
}

- (void)updateMotionWithAccelerationX:(double)ax
                                    y:(double)ay
                                    z:(double)az
                        rotationRateX:(double)gx
                                    y:(double)gy
                                    z:(double)gz
                          orientation:(PPInterfaceOrientation)orientation {
    PlanetPort::Input::SetMotion(ax, ay, az, gx, gy, gz, static_cast<int>(orientation));
}

#pragma mark Save states

- (void)requestSaveStateOp:(SaveStateOp)op slot:(NSUInteger)slot {
    auto session = [self currentSession];
    const bool is_load = op == SaveStateOp::Load;
    if (!session || CurrentState() == PPEmulationStateIdle ||
        CurrentState() == PPEmulationStateStopping || slot > Core::SaveStateSlotCount) {
        ReportSaveStateResult(is_load, static_cast<std::uint32_t>(slot), false);
        return;
    }
    if (session->ss_op.load() != static_cast<int>(SaveStateOp::None)) {
        ReportWarning(MakeError(PPErrorCodeSaveStateFailed,
                                @"Un'altra operazione di salvataggio rapido è in corso."));
        return;
    }
    // The emulation thread reads these once it observes ss_op != None; set them first. It sends
    // the core signal itself right before its next RunLoop (also after a pause ends), so no
    // signal can ever be left pending in the core after this session ends.
    session->ss_slot = static_cast<std::uint32_t>(slot);
    session->ss_wall_time = NowSeconds();
    session->ss_init_count_at_request = session->init_done_count.load();
    session->ss_last_check = {};
    session->ss_signal_sent = false;
    session->ss_op = static_cast<int>(op);
    session->Notify();
}

- (void)saveStateToSlot:(NSUInteger)slot {
    [self requestSaveStateOp:SaveStateOp::Save slot:slot];
}

- (void)loadStateFromSlot:(NSUInteger)slot {
    [self requestSaveStateOp:SaveStateOp::Load slot:slot];
}

- (NSArray<PPSaveStateInfo*>*)saveStatesForTitleID:(uint64_t)titleID {
    if (!g_prepared.load()) {
        return @[];
    }
    return PlanetPort::Console::ListSaveStates(titleID);
}

#pragma mark Stats

- (PPPerformanceStats*)performanceStats {
    auto session = [self currentSession];
    if (!session || CurrentState() != PPEmulationStateRunning) {
        return [[PPPerformanceStats alloc] initWithFPS:0 speed:0 frameTime:0];
    }
    Core::PerfStats::Results results{};
    {
        std::scoped_lock lock{session->stats_mutex};
        results = session->stats;
    }
    return [[PPPerformanceStats alloc] initWithFPS:results.game_fps
                                             speed:results.emulation_speed * 100.0
                                         frameTime:results.time_vblank_interval * 1000.0];
}

#pragma mark Console configuration

- (BOOL)checkIdle:(NSError**)error {
    if (!g_prepared.load()) {
        if (error) {
            *error = MakeError(PPErrorCodeNotPrepared, @"Il core non è stato inizializzato.");
        }
        return NO;
    }
    if (IsGameActive()) {
        if (error) {
            *error = MakeError(PPErrorCodeBusy,
                               @"Chiudi il gioco prima di modificare le impostazioni della "
                               @"console.");
        }
        return NO;
    }
    return YES;
}

- (NSString*)consoleUsername {
    if (!g_prepared.load()) {
        return nil;
    }
    return PlanetPort::Console::GetConsoleUsername();
}

- (BOOL)setConsoleUsername:(NSString*)name error:(NSError**)error {
    if (![self checkIdle:error]) {
        return NO;
    }
    return PlanetPort::Console::SetConsoleUsername(name, error) ? YES : NO;
}

- (PPSystemLanguage)systemLanguage {
    if (!g_prepared.load()) {
        return PPSystemLanguageEnglish;
    }
    return PlanetPort::Console::GetSystemLanguage();
}

- (BOOL)setSystemLanguage:(PPSystemLanguage)language error:(NSError**)error {
    if (![self checkIdle:error]) {
        return NO;
    }
    return PlanetPort::Console::SetSystemLanguage(language, error) ? YES : NO;
}

- (BOOL)regenerateConsoleIDWithError:(NSError**)error {
    if (![self checkIdle:error]) {
        return NO;
    }
    return PlanetPort::Console::RegenerateConsoleID(error) ? YES : NO;
}

- (BOOL)regenerateMACAddressWithError:(NSError**)error {
    if (![self checkIdle:error]) {
        return NO;
    }
    return PlanetPort::Console::RegenerateMACAddress(error) ? YES : NO;
}

#pragma mark Installed titles

- (void)installCIAAtPath:(NSString*)path
                progress:(void (^)(double))progress
              completion:(void (^)(NSError* _Nullable))completion {
    NSError* idleError = nil;
    if (![self checkIdle:&idleError]) {
        RunOnMain(^{
            completion(idleError);
        });
        return;
    }
    NSString* pathCopy = [path copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        auto last_report = std::chrono::steady_clock::time_point{};
        NSError* result = PlanetPort::Console::InstallCIA(
            pathCopy, [&last_report, progress](std::size_t written, std::size_t total) {
                if (progress == nil || total == 0) {
                    return;
                }
                const auto now = std::chrono::steady_clock::now();
                if (written < total && now - last_report < std::chrono::milliseconds(100)) {
                    return;
                }
                last_report = now;
                const double fraction =
                    std::clamp(static_cast<double>(written) / static_cast<double>(total), 0.0, 1.0);
                RunOnMain(^{
                    progress(fraction);
                });
            });
        RunOnMain(^{
            completion(result);
        });
    });
}

- (NSArray<PPGameInfo*>*)installedTitles {
    if (!g_prepared.load()) {
        return @[];
    }
    return PlanetPort::Console::ScanInstalledTitles();
}

@end
