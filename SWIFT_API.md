# Swift service API (contract between App/PlanetPort/Core and App/PlanetPort/UI)

Swift 5.9, iOS 16.0+, SwiftUI + UIKit. `import PlanetCore` gives the Objective-C API in
`core-bridge/include/PlanetCore/*.h`. Value types live in `Core/Models.swift` (already written,
do not redefine them). User-visible strings are Italian. Code comments are English.

Every service below is `@MainActor final class X: ObservableObject` with `static let shared = X()`
and a `private init()`. Signatures are normative: views call exactly these members.

## SettingsStore (Core/SettingsStore.swift)

```swift
enum LeftControlStyle: String, CaseIterable, Identifiable { case circlePad, dPad; var id: String { rawValue }; var label: String }
enum ControllerFaceLayout: String, CaseIterable, Identifiable {
    /// Map by position (bottom face button = 3DS B, right = A, left = Y, top = X). Default.
    case positional
    /// Map by printed label (A->A, B->B, X->X, Y->Y) for Nintendo-style pads.
    case byLabel
    var id: String { rawValue }; var label: String
}

@MainActor final class SettingsStore: ObservableObject {
    static let shared: SettingsStore
    // Emulation (mirror PPSettings, same defaults as +[PPSettings defaultSettings])
    @Published var cpuBackend: PPCPUBackend          // .automatic
    @Published var isNew3DS: Bool                    // true
    @Published var region: PPRegion                  // .automatic
    @Published var cpuClockPercentage: Int           // 100 (range 25...400 in UI)
    @Published var resolutionFactor: Int            // 2 (1...6 in UI; 0 = auto)
    @Published var asyncShaderCompilation: Bool      // true
    @Published var useDiskShaderCache: Bool          // true
    @Published var useVSync: Bool                    // true
    @Published var linearFiltering: Bool             // true
    @Published var landscapeLayout: PPScreenLayout   // .standard
    @Published var portraitLayout: PPPortraitLayout  // .topFullWidth
    @Published var swapScreens: Bool                 // false
    @Published var largeScreenProportion: Double     // 2.25
    @Published var frameLimitPercent: Int            // 100 (0 = unlimited)
    @Published var turboSpeedPercent: Int            // 200
    @Published var volume: Double                    // 1.0
    @Published var audioStretching: Bool             // true
    @Published var microphoneEnabled: Bool           // false
    // App only
    @Published var showPerformanceOverlay: Bool      // false
    @Published var hapticsEnabled: Bool              // true
    @Published var controlsOpacity: Double           // 0.6 (0.15...1)
    @Published var leftControlStyle: LeftControlStyle      // .circlePad
    @Published var controllerFaceLayout: ControllerFaceLayout // .positional
    @Published var motionEnabled: Bool               // true (gyro/accelerometer to the game)
    @Published var hideControlsWithGamepad: Bool     // true

    func makePPSettings() -> PPSettings
    func resetToDefaults()
}
```
Persistence: every property writes `UserDefaults.standard` (keys `"pp.<propertyName>"`, enums
as raw values) in `didSet`; values are loaded in `init`.

## EmulatorController (Core/EmulatorController.swift)

```swift
@MainActor final class EmulatorController: NSObject, ObservableObject, PPEmulatorDelegate {
    static let shared: EmulatorController
    @Published private(set) var state: PPEmulationState          // .idle
    @Published private(set) var currentGame: GameEntry?
    @Published private(set) var shaderProgress: ShaderProgress?   // non-nil only while .loadingShaders
    @Published private(set) var stats: PerformanceSnapshot        // refreshed every 1 s while running
    @Published private(set) var isFastForward: Bool
    @Published var keyboardPrompt: KeyboardPrompt?                // set by the delegate; view clears it after finishing
    @Published var keyboardError: String?                         // last SoftwareKeyboard::ShowError text
    @Published var alert: AppError?                               // fatal stop errors and warnings
    @Published private(set) var toast: String?                    // short transient message (auto-clears after 2.5 s)
    @Published private(set) var isPrepared: Bool

    /// Documents/PlanetPort/ (created by bootstrap()).
    let userDirectory: URL
    var jitAvailable: Bool { get }                                // PPEmulator.isJITAvailable
    var isActive: Bool { get }                                    // state != .idle

    /// Idempotent. Creates the user folder, calls PPEmulator.shared.prepare(withUserDirectory:),
    /// sets the delegate, configures AVAudioSession(.playback, .default), activates
    /// MultiplayerController.shared and starts ControllerManager.shared.
    func bootstrap()

    /// Starts `game` on `layer`. Sets currentGame. On immediate failure sets `alert`.
    func start(game: GameEntry, layer: CAMetalLayer, drawableSize: CGSize, portrait: Bool)
    func stop()
    func pause()
    func resume()
    func togglePause()
    func reset()
    func setFastForward(_ enabled: Bool)
    func updateDrawable(size: CGSize, portrait: Bool)
    /// Pushes SettingsStore.shared.makePPSettings() to PPEmulator.applyRuntimeSettings.
    func applySettings()

    func saveState(slot: Int)          // shows toast on completion
    func loadState(slot: Int)
    func saveStates(for game: GameEntry) -> [PPSaveStateInfo]

    // Input passthrough (cheap; may also be called from non-main threads via PPEmulator.shared directly)
    func setButton(_ button: PPButton, pressed: Bool)
    func setStick(_ stick: PPAnalogStick, x: Float, y: Float)
    func releaseAllInputs()
    @discardableResult func touchBegan(at pixel: CGPoint) -> Bool
    func touchMoved(to pixel: CGPoint)
    func touchEnded()

    /// .background/.inactive: pause if running (remember auto-pause). .active: resume if auto-paused.
    func handleScenePhase(_ phase: ScenePhase)
}
```
While running: `UIApplication.shared.isIdleTimerDisabled = true`, MotionProvider started when
`SettingsStore.shared.motionEnabled`. On `didStopWithError`: currentGame = nil, timers stopped,
idle timer re-enabled, MotionProvider stopped, `alert` set when error != nil.

## GameLibrary (Core/GameLibrary.swift)

```swift
@MainActor final class GameLibrary: ObservableObject {
    static let shared: GameLibrary
    static let supportedExtensions: Set<String>  // 3ds cci cxi app 3dsx elf axf zcci zcxi z3dsx bcci bcxi cia zcia bcia
    @Published private(set) var games: [GameEntry]         // sorted: Planet Robobot first, then title
    @Published private(set) var pendingCIAs: [URL]          // .cia files found in gamesDirectory, not yet installed
    @Published private(set) var isBusy: Bool
    @Published private(set) var busyMessage: String?        // Italian, e.g. "Installazione CIA…"
    @Published private(set) var progress: Double?           // 0...1 while copying/installing
    @Published var alert: AppError?
    /// Documents/PlanetPort/games/
    let gamesDirectory: URL
    var featuredGame: GameEntry? { get }                    // first isPlanetRobobot

    /// Scans gamesDirectory (PPGameInfo per supported file, off the main thread) and
    /// PPEmulator.shared.installedTitles(); updates games / pendingCIAs.
    func refresh() async
    /// Files picked with .fileImporter (security-scoped). Bootable files are copied into
    /// gamesDirectory (overwrite after confirmation is not needed: replace silently);
    /// .cia files are installed directly from the picked URL. Then refresh().
    func importFiles(_ urls: [URL]) async
    func installPendingCIA(_ url: URL, deleteAfterInstall: Bool) async
    /// Deletes a ROM file from gamesDirectory. Installed titles cannot be deleted (alert).
    func delete(_ game: GameEntry)
}
```
Encrypted games are listed (with `isEncrypted`) so the UI can explain why they cannot start.

## MultiplayerController (Core/MultiplayerController.swift)

```swift
@MainActor final class MultiplayerController: NSObject, ObservableObject, PPMultiplayerDelegate {
    static let shared: MultiplayerController
    @Published private(set) var isJoined: Bool
    @Published private(set) var isHosting: Bool
    @Published private(set) var isModerator: Bool
    @Published private(set) var roomName: String?
    @Published private(set) var members: [RoomMemberEntry]
    @Published private(set) var chat: [ChatLine]            // includes system lines
    @Published private(set) var unreadCount: Int
    @Published private(set) var isBusy: Bool
    @Published private(set) var nickname: String            // console user name
    @Published var alert: AppError?
    let discovery: RoomDiscovery

    /// Called once by EmulatorController.bootstrap(): sets the PPMultiplayer delegate, activate(), loads nickname.
    func activate()
    /// Validates (PPMultiplayer.isValidNickname) and stores via PPEmulator.setConsoleUsername.
    /// Returns an Italian error message, or nil on success.
    func setNickname(_ name: String) -> String?
    func host(name: String, port: UInt16, password: String, maxPlayers: Int) async -> Bool   // also publishes via discovery
    func join(address: String, port: UInt16, password: String) async -> Bool
    func join(room: DiscoveredRoom, password: String) async -> Bool
    func leave() async                                        // also unpublishes
    func send(_ text: String)
    func kick(_ nickname: String)
    func ban(_ nickname: String)
    func markChatRead()
    /// Regenerate console identity (only when no game runs). Return Italian error or nil.
    func regenerateConsoleID() -> String?
    func regenerateMACAddress() -> String?
    /// Non-loopback IPv4 addresses of this device (Wi-Fi first), for "tell your friends this IP".
    static func localIPAddresses() -> [String]
}
```

## RoomDiscovery (Core/RoomDiscovery.swift)

```swift
@MainActor final class RoomDiscovery: NSObject, ObservableObject /* NetServiceBrowserDelegate, NetServiceDelegate */ {
    static let serviceType: String                 // "_planetport._tcp."
    @Published private(set) var rooms: [DiscoveredRoom]
    @Published private(set) var isBrowsing: Bool
    func startBrowsing()
    func stopBrowsing()
    func publish(roomName: String, port: UInt16, hasPassword: Bool, gameName: String)
    func unpublish()
}
```
Not a singleton: owned by MultiplayerController. TXT keys: `room`, `pw` ("1"/"0"), `game`.
The device's own published service is filtered out of `rooms`.

## ControllerManager (Core/ControllerManager.swift)

```swift
@MainActor final class ControllerManager: ObservableObject {
    static let shared: ControllerManager
    @Published private(set) var controllerName: String?   // nil when none connected
    var isControllerConnected: Bool { get }
    func start()   // idempotent; observes GCControllerDidConnect/DidDisconnect, wires extendedGamepad handlers
}
```
Mapping: d-pad -> Up/Down/Left/Right, left stick -> circle pad, right stick -> C-stick,
leftShoulder/rightShoulder -> L/R, leftTrigger/rightTrigger -> ZL/ZR, buttonMenu -> Start,
buttonOptions -> Select, face buttons per `SettingsStore.controllerFaceLayout`. Handlers call
`PPEmulator.shared` input methods directly (thread-safe).

## MotionProvider (Core/MotionProvider.swift)

```swift
final class MotionProvider {
    static let shared: MotionProvider
    /// Updated by EmulationView when the interface orientation changes.
    var orientation: PPInterfaceOrientation   // atomic-safe (protected by a lock)
    func start()   // CMMotionManager deviceMotion at 60 Hz on a private OperationQueue
    func stop()
}
```
Sample = gravity + userAcceleration (g) and rotationRate (rad/s), forwarded to
`PPEmulator.shared.updateMotion(accelerationX:y:z:rotationRateX:y:z:orientation:)`.

## Haptics (Core/Haptics.swift)

```swift
@MainActor enum Haptics {
    static func buttonDown()   // light impact, only if SettingsStore.shared.hapticsEnabled
}
```

## UI entry points (UI/)

* `PlanetPortApp` (`@main`): `WindowGroup { RootView() }`, injects every service with
  `.environmentObject`, calls `EmulatorController.shared.bootstrap()` and
  `Task { await GameLibrary.shared.refresh() }` on appear, forwards `scenePhase`.
* `RootView`: `NavigationStack { HomeView() }` + `.fullScreenCover(item:)` presenting
  `EmulationView(game:)` for the selected game.
* `EmulationView(game: GameEntry)`: owns `MetalScreenView` (calls
  `EmulatorController.start` once the layer has a non-zero size), `GamepadOverlay`, the pause
  menu, `SaveStatesView`, `MultiplayerView`, `KeyboardPromptView`. Dismisses only after the
  controller reports `.idle` following a stop.
