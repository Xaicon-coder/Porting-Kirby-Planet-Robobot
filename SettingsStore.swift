// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Persistent user settings. Every property is mirrored to UserDefaults ("pp.<propertyName>",
// enums stored as raw values) and converted to a PPSettings for the bridge on demand.

import Combine
import Foundation
import PlanetCore

/// Style of the left on-screen directional control.
enum LeftControlStyle: String, CaseIterable, Identifiable {
    case circlePad
    case dPad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circlePad: return "Circle Pad"
        case .dPad: return "Croce direzionale"
        }
    }
}

/// How the face buttons of an external game controller map to the 3DS face buttons.
enum ControllerFaceLayout: String, CaseIterable, Identifiable {
    /// Map by position (bottom face button = 3DS B, right = A, left = Y, top = X). Default.
    case positional
    /// Map by printed label (A->A, B->B, X->X, Y->Y) for Nintendo-style pads.
    case byLabel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .positional: return "Per posizione (Xbox, PlayStation)"
        case .byLabel: return "Per etichetta (stile Nintendo)"
        }
    }

    /// Thread-safe read of the persisted layout. Used by game controller input handlers, which
    /// must not touch the main-actor isolated SettingsStore.
    static func persistedValue() -> ControllerFaceLayout {
        guard let raw = UserDefaults.standard.string(forKey: SettingsStoreKey.controllerFaceLayout),
              let layout = ControllerFaceLayout(rawValue: raw) else {
            return SettingsStoreDefault.controllerFaceLayout
        }
        return layout
    }
}

/// UserDefaults keys ("pp.<propertyName>").
private enum SettingsStoreKey {
    static let cpuBackend = "pp.cpuBackend"
    static let isNew3DS = "pp.isNew3DS"
    static let region = "pp.region"
    static let cpuClockPercentage = "pp.cpuClockPercentage"
    static let resolutionFactor = "pp.resolutionFactor"
    static let asyncShaderCompilation = "pp.asyncShaderCompilation"
    static let useDiskShaderCache = "pp.useDiskShaderCache"
    static let useVSync = "pp.useVSync"
    static let linearFiltering = "pp.linearFiltering"
    static let landscapeLayout = "pp.landscapeLayout"
    static let portraitLayout = "pp.portraitLayout"
    static let swapScreens = "pp.swapScreens"
    static let largeScreenProportion = "pp.largeScreenProportion"
    static let frameLimitPercent = "pp.frameLimitPercent"
    static let turboSpeedPercent = "pp.turboSpeedPercent"
    static let volume = "pp.volume"
    static let audioStretching = "pp.audioStretching"
    static let microphoneEnabled = "pp.microphoneEnabled"
    static let showPerformanceOverlay = "pp.showPerformanceOverlay"
    static let hapticsEnabled = "pp.hapticsEnabled"
    static let controlsOpacity = "pp.controlsOpacity"
    static let leftControlStyle = "pp.leftControlStyle"
    static let controllerFaceLayout = "pp.controllerFaceLayout"
    static let motionEnabled = "pp.motionEnabled"
    static let hideControlsWithGamepad = "pp.hideControlsWithGamepad"
}

/// Default values. The emulation ones match +[PPSettings defaultSettings].
private enum SettingsStoreDefault {
    static let cpuBackend = PPCPUBackend.automatic
    static let isNew3DS = true
    static let region = PPRegion.automatic
    static let cpuClockPercentage = 100
    static let resolutionFactor = 2
    static let asyncShaderCompilation = true
    static let useDiskShaderCache = true
    static let useVSync = true
    static let linearFiltering = true
    static let landscapeLayout = PPScreenLayout.standard
    static let portraitLayout = PPPortraitLayout.topFullWidth
    static let swapScreens = false
    static let largeScreenProportion = 2.25
    static let frameLimitPercent = 100
    static let turboSpeedPercent = 200
    static let volume = 1.0
    static let audioStretching = true
    static let microphoneEnabled = false
    static let showPerformanceOverlay = false
    static let hapticsEnabled = true
    static let controlsOpacity = 0.6
    static let leftControlStyle = LeftControlStyle.circlePad
    static let controllerFaceLayout = ControllerFaceLayout.positional
    static let motionEnabled = true
    static let hideControlsWithGamepad = true

    // Valid cases of the imported C enums (their init(rawValue:) does not validate).
    static let cpuBackends: [PPCPUBackend] = [.automatic, .jit, .interpreter]
    static let regions: [PPRegion] = [.automatic, .japan, .usa, .europe, .australia, .china, .korea, .taiwan]
    static let landscapeLayouts: [PPScreenLayout] = [.standard, .singleScreen, .largeScreen, .sideBySide, .hybrid]
    static let portraitLayouts: [PPPortraitLayout] = [.topFullWidth, .original]
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // MARK: Emulation (mirrors PPSettings)

    @Published var cpuBackend: PPCPUBackend {
        didSet { defaults.set(cpuBackend.rawValue, forKey: SettingsStoreKey.cpuBackend) }
    }
    @Published var isNew3DS: Bool {
        didSet { defaults.set(isNew3DS, forKey: SettingsStoreKey.isNew3DS) }
    }
    @Published var region: PPRegion {
        didSet { defaults.set(region.rawValue, forKey: SettingsStoreKey.region) }
    }
    @Published var cpuClockPercentage: Int {
        didSet { defaults.set(cpuClockPercentage, forKey: SettingsStoreKey.cpuClockPercentage) }
    }
    @Published var resolutionFactor: Int {
        didSet { defaults.set(resolutionFactor, forKey: SettingsStoreKey.resolutionFactor) }
    }
    @Published var asyncShaderCompilation: Bool {
        didSet { defaults.set(asyncShaderCompilation, forKey: SettingsStoreKey.asyncShaderCompilation) }
    }
    @Published var useDiskShaderCache: Bool {
        didSet { defaults.set(useDiskShaderCache, forKey: SettingsStoreKey.useDiskShaderCache) }
    }
    @Published var useVSync: Bool {
        didSet { defaults.set(useVSync, forKey: SettingsStoreKey.useVSync) }
    }
    @Published var linearFiltering: Bool {
        didSet { defaults.set(linearFiltering, forKey: SettingsStoreKey.linearFiltering) }
    }
    @Published var landscapeLayout: PPScreenLayout {
        didSet { defaults.set(landscapeLayout.rawValue, forKey: SettingsStoreKey.landscapeLayout) }
    }
    @Published var portraitLayout: PPPortraitLayout {
        didSet { defaults.set(portraitLayout.rawValue, forKey: SettingsStoreKey.portraitLayout) }
    }
    @Published var swapScreens: Bool {
        didSet { defaults.set(swapScreens, forKey: SettingsStoreKey.swapScreens) }
    }
    @Published var largeScreenProportion: Double {
        didSet { defaults.set(largeScreenProportion, forKey: SettingsStoreKey.largeScreenProportion) }
    }
    @Published var frameLimitPercent: Int {
        didSet { defaults.set(frameLimitPercent, forKey: SettingsStoreKey.frameLimitPercent) }
    }
    @Published var turboSpeedPercent: Int {
        didSet { defaults.set(turboSpeedPercent, forKey: SettingsStoreKey.turboSpeedPercent) }
    }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: SettingsStoreKey.volume) }
    }
    @Published var audioStretching: Bool {
        didSet { defaults.set(audioStretching, forKey: SettingsStoreKey.audioStretching) }
    }
    @Published var microphoneEnabled: Bool {
        didSet { defaults.set(microphoneEnabled, forKey: SettingsStoreKey.microphoneEnabled) }
    }

    // MARK: App only

    @Published var showPerformanceOverlay: Bool {
        didSet { defaults.set(showPerformanceOverlay, forKey: SettingsStoreKey.showPerformanceOverlay) }
    }
    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: SettingsStoreKey.hapticsEnabled) }
    }
    @Published var controlsOpacity: Double {
        didSet { defaults.set(controlsOpacity, forKey: SettingsStoreKey.controlsOpacity) }
    }
    @Published var leftControlStyle: LeftControlStyle {
        didSet { defaults.set(leftControlStyle.rawValue, forKey: SettingsStoreKey.leftControlStyle) }
    }
    @Published var controllerFaceLayout: ControllerFaceLayout {
        didSet { defaults.set(controllerFaceLayout.rawValue, forKey: SettingsStoreKey.controllerFaceLayout) }
    }
    @Published var motionEnabled: Bool {
        didSet { defaults.set(motionEnabled, forKey: SettingsStoreKey.motionEnabled) }
    }
    @Published var hideControlsWithGamepad: Bool {
        didSet { defaults.set(hideControlsWithGamepad, forKey: SettingsStoreKey.hideControlsWithGamepad) }
    }

    // MARK: Init

    private init() {
        let store = UserDefaults.standard
        typealias K = SettingsStoreKey
        typealias D = SettingsStoreDefault

        cpuBackend = SettingsStore.loadEnum(store, K.cpuBackend, D.cpuBackend, allowed: D.cpuBackends)
        isNew3DS = SettingsStore.loadBool(store, K.isNew3DS, D.isNew3DS)
        region = SettingsStore.loadEnum(store, K.region, D.region, allowed: D.regions)
        cpuClockPercentage = SettingsStore.loadInt(store, K.cpuClockPercentage, D.cpuClockPercentage, range: 5...400)
        resolutionFactor = SettingsStore.loadInt(store, K.resolutionFactor, D.resolutionFactor, range: 0...10)
        asyncShaderCompilation = SettingsStore.loadBool(store, K.asyncShaderCompilation, D.asyncShaderCompilation)
        useDiskShaderCache = SettingsStore.loadBool(store, K.useDiskShaderCache, D.useDiskShaderCache)
        useVSync = SettingsStore.loadBool(store, K.useVSync, D.useVSync)
        linearFiltering = SettingsStore.loadBool(store, K.linearFiltering, D.linearFiltering)
        landscapeLayout = SettingsStore.loadEnum(store, K.landscapeLayout, D.landscapeLayout, allowed: D.landscapeLayouts)
        portraitLayout = SettingsStore.loadEnum(store, K.portraitLayout, D.portraitLayout, allowed: D.portraitLayouts)
        swapScreens = SettingsStore.loadBool(store, K.swapScreens, D.swapScreens)
        largeScreenProportion = SettingsStore.loadDouble(store, K.largeScreenProportion, D.largeScreenProportion, range: 1...16)
        frameLimitPercent = SettingsStore.loadInt(store, K.frameLimitPercent, D.frameLimitPercent, range: 0...1000)
        turboSpeedPercent = SettingsStore.loadInt(store, K.turboSpeedPercent, D.turboSpeedPercent, range: 0...1000)
        volume = SettingsStore.loadDouble(store, K.volume, D.volume, range: 0...1)
        audioStretching = SettingsStore.loadBool(store, K.audioStretching, D.audioStretching)
        microphoneEnabled = SettingsStore.loadBool(store, K.microphoneEnabled, D.microphoneEnabled)

        showPerformanceOverlay = SettingsStore.loadBool(store, K.showPerformanceOverlay, D.showPerformanceOverlay)
        hapticsEnabled = SettingsStore.loadBool(store, K.hapticsEnabled, D.hapticsEnabled)
        controlsOpacity = SettingsStore.loadDouble(store, K.controlsOpacity, D.controlsOpacity, range: 0.15...1)
        leftControlStyle = SettingsStore.loadStringEnum(store, K.leftControlStyle, D.leftControlStyle)
        controllerFaceLayout = SettingsStore.loadStringEnum(store, K.controllerFaceLayout, D.controllerFaceLayout)
        motionEnabled = SettingsStore.loadBool(store, K.motionEnabled, D.motionEnabled)
        hideControlsWithGamepad = SettingsStore.loadBool(store, K.hideControlsWithGamepad, D.hideControlsWithGamepad)
    }

    // MARK: API

    /// Builds the bridge configuration from the current values (clamped to the core's ranges).
    func makePPSettings() -> PPSettings {
        // -[PPSettings init] fills the same defaults as +defaultSettings (PPSettings.mm), and every
        // property is assigned below. Avoids the factory, whose Swift import name is pruned by
        // omit-needless-words (defaultSettings -> default()).
        let settings = PPSettings()
        settings.cpuBackend = cpuBackend
        settings.isNew3DS = isNew3DS
        settings.region = region
        settings.cpuClockPercentage = SettingsStore.clamp(cpuClockPercentage, 5...400)
        settings.resolutionFactor = SettingsStore.clamp(resolutionFactor, 0...10)
        settings.asyncShaderCompilation = asyncShaderCompilation
        settings.useDiskShaderCache = useDiskShaderCache
        settings.useVSync = useVSync
        settings.linearFiltering = linearFiltering
        settings.landscapeLayout = landscapeLayout
        settings.portraitLayout = portraitLayout
        settings.swapScreens = swapScreens
        settings.largeScreenProportion = Float(SettingsStore.clamp(largeScreenProportion, 1...16))
        settings.frameLimitPercent = SettingsStore.clamp(frameLimitPercent, 0...1000)
        settings.turboSpeedPercent = SettingsStore.clamp(turboSpeedPercent, 0...1000)
        settings.volume = Float(SettingsStore.clamp(volume, 0...1))
        settings.audioStretching = audioStretching
        settings.microphoneEnabled = microphoneEnabled
        return settings
    }

    /// Restores every setting (emulation and app) to its default value.
    func resetToDefaults() {
        typealias D = SettingsStoreDefault
        cpuBackend = D.cpuBackend
        isNew3DS = D.isNew3DS
        region = D.region
        cpuClockPercentage = D.cpuClockPercentage
        resolutionFactor = D.resolutionFactor
        asyncShaderCompilation = D.asyncShaderCompilation
        useDiskShaderCache = D.useDiskShaderCache
        useVSync = D.useVSync
        linearFiltering = D.linearFiltering
        landscapeLayout = D.landscapeLayout
        portraitLayout = D.portraitLayout
        swapScreens = D.swapScreens
        largeScreenProportion = D.largeScreenProportion
        frameLimitPercent = D.frameLimitPercent
        turboSpeedPercent = D.turboSpeedPercent
        volume = D.volume
        audioStretching = D.audioStretching
        microphoneEnabled = D.microphoneEnabled
        showPerformanceOverlay = D.showPerformanceOverlay
        hapticsEnabled = D.hapticsEnabled
        controlsOpacity = D.controlsOpacity
        leftControlStyle = D.leftControlStyle
        controllerFaceLayout = D.controllerFaceLayout
        motionEnabled = D.motionEnabled
        hideControlsWithGamepad = D.hideControlsWithGamepad
    }

    // MARK: Loading helpers

    private static func loadBool(_ store: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        (store.object(forKey: key) as? NSNumber)?.boolValue ?? fallback
    }

    private static func loadInt(_ store: UserDefaults, _ key: String, _ fallback: Int,
                                range: ClosedRange<Int>) -> Int {
        guard let number = store.object(forKey: key) as? NSNumber else { return fallback }
        return clamp(number.intValue, range)
    }

    private static func loadDouble(_ store: UserDefaults, _ key: String, _ fallback: Double,
                                   range: ClosedRange<Double>) -> Double {
        guard let number = store.object(forKey: key) as? NSNumber else { return fallback }
        let value = number.doubleValue
        return value.isFinite ? clamp(value, range) : fallback
    }

    private static func loadEnum<T: RawRepresentable>(_ store: UserDefaults, _ key: String, _ fallback: T,
                                                      allowed: [T]) -> T where T.RawValue == Int {
        guard let number = store.object(forKey: key) as? NSNumber else { return fallback }
        let raw = number.intValue
        return allowed.first { $0.rawValue == raw } ?? fallback
    }

    private static func loadStringEnum<T: RawRepresentable>(_ store: UserDefaults, _ key: String,
                                                            _ fallback: T) -> T where T.RawValue == String {
        guard let raw = store.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }

    private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
