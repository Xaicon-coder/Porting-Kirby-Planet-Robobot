# PlanetPort architecture

PlanetPort is a native iOS app (SwiftUI + UIKit) that plays the user's own decrypted dump of
*Kirby: Planet Robobot* (or any other 3DS game) by embedding the open-source **Azahar** 3DS
emulator core (GPLv2+). No ROM, key, firmware or Nintendo asset ships with the app.

```
┌──────────────────────────── PlanetPort.app (Swift) ────────────────────────────┐
│ UI/ (SwiftUI + UIKit overlay)   Core/ (services, @MainActor ObservableObjects)  │
│        │                                   │                                    │
│        └────────────── import PlanetCore ──┘                                    │
├──────────────────── PlanetCore.framework (Objective-C++ bridge) ───────────────┤
│ PPEmulator  PPMultiplayer  PPGameInfo  PPSettings   (public ObjC headers)       │
│ PPEmuWindow (Frontend::EmuWindow + CAMetalLayer)  PPInput  PPApplets  PPSystem  │
├──────────── Azahar static libraries (linked into the framework) ───────────────┤
│ citra_core video_core(Vulkan) audio_core(OpenAL Soft) network(ENet) input_common │
│ citra_common + externals (dynarmic, oaknut, boost, fmt, glslang, sirit, ...)     │
├──────────────────────────── MoltenVK (static, force_load) ─────────────────────┤
│                                 Metal                                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Pinned core: `azahar-emu/azahar` commit `12bde376ce8fc2012af61ea791f94172a82e67e0`
(2026-10-24). MoltenVK v1.4.1 is downloaded by Azahar's CMake.

## Repository layout

```
PlanetPort/
  README.md                      Italian user guide (build, ROM dump, JIT, multiplayer)
  docs/ARCHITECTURE.md           this file
  scripts/
    bootstrap.sh                 one command: check tools, fetch, patch, build core, xcodegen
    fetch_azahar.sh              clone azahar at the pinned commit + submodules
    patch_azahar.py              exact-anchor source patches (fails loudly if an anchor moved)
    build_core.sh                configure + build PlanetCore.framework for iphoneos arm64
  core-bridge/
    CMakeLists.txt               PlanetCore framework target (added INTO azahar's build tree)
    module.modulemap             copied to PlanetCore.framework/Modules
    ios/apple_utils_ios.mm       UIKit replacement for azahar's Cocoa-only apple_utils.mm
    include/PlanetCore/*.h       PUBLIC Objective-C API (the contract; do not change lightly)
    src/PPInternal.h             PRIVATE Objective-C++ contract between bridge files
    src/*.mm                     implementation
  App/
    project.yml                  XcodeGen spec
    PlanetPort/
      Info.plist, PlanetPort.entitlements, Assets.xcassets
      Core/                      services (Swift)
      UI/                        views (Swift)
```

## Core patches (scripts/patch_azahar.py)

1. `src/common/CMakeLists.txt`: on `IOS`, compile `apple_utils_ios.mm` (copied from
   `core-bridge/ios/`) instead of the Cocoa-only `apple_utils.mm`.
2. `src/video_core/renderer_vulkan/vk_platform.cpp`: on iOS (`TARGET_OS_IPHONE`), `OpenLibrary`
   returns `context->GetDriverLibrary()` when non-null and loaded, else a `DynamicLibrary`
   wrapping `dlopen(nullptr, RTLD_NOW)`. MoltenVK is statically linked, so the stock
   `dlopen("libvulkan.dylib")`/`libMoltenVK.dylib` lookup would fail and throw.
3. `src/CMakeLists.txt`: append
   `if (PLANETPORT_BRIDGE_DIR) add_subdirectory(${PLANETPORT_BRIDGE_DIR} ${CMAKE_BINARY_DIR}/planetport_bridge) endif()`
   so the bridge is configured inside azahar's directory scope (inherits `include_directories(src)`,
   compile definitions such as `ENABLE_VULKAN`, and `CMAKE_SOURCE_DIR` stays azahar's root,
   which azahar's externals rely on).

No other non-Qt core file uses macOS-only APIs (verified by grep at the pinned commit).
oaknut (JIT code blocks) already handles `TARGET_OS_IPHONE` with RW<->RX `mprotect` toggling.

## Build (on a Mac)

```
cmake -S azahar -B build/core -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_QT=OFF -DENABLE_QT_TRANSLATION=OFF -DENABLE_SDL2=OFF -DENABLE_TESTS=OFF \
  -DENABLE_ROOM=OFF -DENABLE_WEB_SERVICE=OFF -DENABLE_SCRIPTING=OFF -DENABLE_GDBSTUB=OFF \
  -DENABLE_CUBEB=OFF -DENABLE_LIBUSB=OFF -DENABLE_OPENAL=ON -DENABLE_VULKAN=ON \
  -DENABLE_OPENGL=OFF -DENABLE_SOFTWARE_RENDERER=ON -DENABLE_LIBRETRO=OFF \
  -DENABLE_BUILTIN_KEYBLOB=OFF -DENABLE_LTO=OFF -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
  -DCITRA_WARNINGS_AS_ERRORS=OFF -DENABLE_OPT=OFF \
  -DPLANETPORT_BRIDGE_DIR=$PWD/core-bridge
cmake --build build/core --target PlanetCore
```

`PlanetCore` is a SHARED library with `FRAMEWORK TRUE`. Linking it lets CMake resolve the whole
transitive static-library graph of azahar. MoltenVK (`MOLTENVK_LIBRARY`, set by azahar's CMake)
is linked with `-Wl,-force_load`. System frameworks: Foundation, CoreFoundation, UIKit, Metal,
QuartzCore, IOSurface, CoreGraphics, AVFoundation, AudioToolbox, CoreAudio. The framework gets
`Modules/module.modulemap`, an install name of `@rpath/PlanetCore.framework/PlanetCore` and
deployment target 14.0 (azahar forces it). The Xcode app (deployment target 16.0) embeds and
signs it.

## Bridge threading model

* **Main thread**: every public API except where noted; all delegate callbacks are delivered
  on the main queue (`RunOnMain`, always async).
* **Emulation thread** (`NSThread`, 8 MB stack, QoS user-interactive), one per boot. It does
  *everything* with `Core::System`: settings application, `System::Load`, disk shader cache,
  the `RunLoop` loop, error handling, and `System::Shutdown`. This mirrors the Android frontend
  (`src/android/app/src/main/jni/native.cpp` `RunCitra`).
* Pause/resume/stop/pending work use `std::atomic` flags + one `std::mutex`/`std::condition_variable`.
  Pending work processed by the loop *between* `RunLoop()` calls: layout change
  (`EmuWindow::UpdateCurrentFramebufferLayout`), runtime settings (`System::ApplySettings()`
  followed by `Renderer().UpdateCurrentFramebufferLayout(portrait)`, because on non-Android
  builds ApplySettings re-lays out with portrait=false), reset.
* Save/load state and reset requests are only *recorded* by the main thread. The emulation
  thread sends `System::SendSignal(Signal::Save|Load|Reset, slot)` itself right before the
  `RunLoop` that consumes it, so no signal can stay pending in the core after a session ends and
  fire on the next boot. Save completion is detected from the state file's header time, load
  completion from the core's init callback; failures come back as `RunLoop` statuses.
* Performance statistics are sampled by the emulation thread once per second (Reset and
  LoadState destroy and recreate the core's `PerfStats` object, so the main thread never reads
  it directly).
* The software keyboard blocks the emulation thread inside `RunLoop`. Stopping sets a sticky
  cancellation that completes the pending request and every later one until the next boot.
* `System::ApplySettings()` is run under the window lock and followed by the real
  (portrait-aware) layout, because on non-Android builds it re-lays out with portrait = false.
* Each loop iteration runs in an `@autoreleasepool`; so does every multiplayer callback (the
  RoomMember loop thread is a plain `std::thread`).
* Input (buttons, sticks, motion) is lock-free atomics read by the core's HID on the emulation
  thread. Touch calls `EmuWindow::TouchPressed/Moved/Released` under the window mutex that also
  guards layout updates.
* `PollEvents()` is called by the renderer every frame on the emulation thread; it is a cheap
  no-op.

### Boot sequence (emulation thread)

1. `Loader::GetLoader(path)`; `ReadProgramId` -> `runningTitleID`; `RegisterAppLoaderEarly`.
2. Decide JIT: `PPCPUBackendAuto` -> `IsJITAvailable()`; `PPCPUBackendJIT` without JIT ->
   interpreter + warning; `PPCPUBackendInterpreter` -> interpreter.
3. `ApplyBootSettings(settings, use_jit)`; `Input::ConfigureInputProfile()`;
   `system.ApplySettings()`; `Settings::LogSettings()`.
4. `Frontend::RegisterDefaultApplets(system)`; `system.RegisterSoftwareKeyboard(Applets::CreateSoftwareKeyboard())`;
   `system.RegisterMicPermissionCheck(AppleAuthorization::CheckAuthorizationForMicrophone)` when
   the microphone is enabled.
5. Create `PPEmuWindow` (`WindowSystemType::MacOS`, `render_surface = CAMetalLayer*`,
   `GetDriverLibrary()` returns the image that contains MoltenVK), lay it out.
6. `system.Load(*window, path)` inside `try/catch(const std::exception&)`.
7. `GPU().ApplyPerProgramSettings(program_id)`;
   `GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(stop_flag, progress_cb)`.
8. `RegisterCoreLoopThreadId()`; loop; on exit `window->DoneCurrent()`, `system.Shutdown()`,
   `window.reset()`, state Idle, `didStopWithError:`.

`RunLoop` results: `Success` continue; `ShutdownRequested` stop (no error);
`ErrorSavestate`/`ErrorSavestateBuildMismatch` -> warning, continue;
`ErrorSystemFiles` -> warning once, continue; anything else -> stop with that error.

### Global prepare (main thread, once)

`FileUtil::SetUserPath(dir + "/")` **before anything calls GetUserPath** -> create every
`FileUtil::UserPath` sub-directory -> `Common::Log::Initialize(); Start();`
(+ console backend in DEBUG) -> `ApplyGlobalDefaults()` -> `Input::RegisterFactories()` ->
`Network::Init()`.

User directory used by the app: `Documents/PlanetPort/` (visible in the Files app):
`games/` (ROMs imported by the app) plus Azahar's `config/ sdmc/ nand/ sysdata/ shaders/
states/ cheats/ log/ ...`.

## Multiplayer

Azahar emulates the 3DS local wireless service (NWM_UDS) over a *room*: an ENet/UDP relay.
Team Kirby Clash's local multiplayer runs through it. Every player runs their own copy of the
game. PlanetPort can:

* **Host** in-process: `Room::Create(name, "", "", port, password, max, nickname, game, game_id,
  NullBackend, {})`, then `RoomMember::Join(nickname, CFG console-id hash, "127.0.0.1", port, 0,
  CFG console MAC, password)` (Qt's approach).
* **Join** by address/port (+ password).
* **Discover** rooms on the same Wi-Fi via Bonjour (`_planetport._tcp`, Swift side,
  NetService), advertising name/port/password flag/game in the TXT record.
* Internet play: port forwarding of UDP 24872 on the host's router, or a mesh VPN
  (Tailscale/ZeroTier). No public lobby server exists for Azahar, so the web service is off.

Nickname = CFG console user name (4...10 chars `[ a-zA-Z0-9._-]`). Join must use a unique
nickname, console ID and MAC: the settings screen can regenerate the console ID and MAC.
`Network::Init()` runs during prepare (before any `System::Load`) because NWM_UDS binds to the
RoomMember when the game boots.

## JIT

Dynarmic + the shader JIT need executable memory, which iOS grants only to processes with a
debugger attached (`CS_DEBUGGED`; e.g. StikDebug, SideStore + JIT enabler, Xcode). PlanetPort
detects it at boot (`csops` + `mprotect` probe) and otherwise uses Azahar's FastInterp CPU
interpreter + shader interpreter (always works, slower). Devices on iOS 26 with TXM may refuse
the RW<->RX toggle used by oaknut even with a debugger: the probe catches that and the app falls
back to the interpreter.

## Swift side

All services are `@MainActor final class ... : ObservableObject` singletons (`static let shared`).

Every Objective-C method and delegate requirement used from Swift has an explicit
`NS_SWIFT_NAME`, so Swift names never depend on the importer's "omit needless words" heuristics
(for example `drawableSize:` with a `CGSize` parameter would otherwise become `drawable:`).
`+[PPGameInfo gameInfoAtPath:error:]` is imported by the standard factory rule as
`PPGameInfo(atPath:) throws`.

In landscape the touch-control overlay covers the render view: it takes every touch and forwards
the ones that are not on a control to `MetalHostView.current`, so the emulated touch screen does
not depend on SwiftUI passing touches between overlapping `UIViewRepresentable`s.

| File | Type | Role |
|---|---|---|
| Core/Models.swift | value types | GameEntry, AppError, ShaderProgress, PerformanceSnapshot, KeyboardPrompt, ChatLine, RoomMemberEntry, DiscoveredRoom |
| Core/EmulatorController.swift | `EmulatorController` | wraps PPEmulator, delegate, stats timer, scene-phase auto pause |
| Core/GameLibrary.swift | `GameLibrary` | games folder scan, import (copy / CIA install), installed titles |
| Core/SettingsStore.swift | `SettingsStore` + enums | UserDefaults persistence, `makePPSettings()` |
| Core/MultiplayerController.swift | `MultiplayerController` | wraps PPMultiplayer, chat, nickname |
| Core/RoomDiscovery.swift | `RoomDiscovery` | Bonjour publish/browse |
| Core/ControllerManager.swift | `ControllerManager` | GameController (MFi/Xbox/PS/Switch pads) |
| Core/MotionProvider.swift | `MotionProvider` | CoreMotion -> PPEmulator |
| Core/Haptics.swift | `Haptics` | button feedback |
| UI/PlanetPortApp.swift | `@main` | scene, environment objects, scene phase |
| UI/RootView.swift, HomeView.swift, GameRowView.swift | | library + featured Kirby card + import |
| UI/EmulationView.swift | | in-game screen, menu, overlays, keyboard sheet |
| UI/MetalScreenView.swift | `MetalScreenView` (UIViewRepresentable) + `MetalHostView` (UIView, `CAMetalLayer` layerClass) | render surface + touch |
| UI/GamepadOverlayView.swift | `GamepadOverlay` (UIViewRepresentable) + `GamepadOverlayUIView` (UIKit multitouch) | on-screen controls |
| UI/MultiplayerView.swift, ChatView.swift | | rooms, LAN discovery, chat |
| UI/SettingsView.swift, SaveStatesView.swift, AboutView.swift, KeyboardPromptView.swift | | |

The exact Swift service APIs are specified in `docs/SWIFT_API.md`.
