// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Shared enums and error definitions. This header is pure Objective-C (no C++) so Swift can
// import it through the PlanetCore framework module.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for every NSError produced by PlanetCore.
FOUNDATION_EXPORT NSErrorDomain const PPErrorDomain;
/// userInfo key holding Core::System::GetStatusDetails() (English, may be empty).
FOUNDATION_EXPORT NSString *const PPErrorCoreDetailsKey;

typedef NS_ERROR_ENUM(PPErrorDomain, PPErrorCode) {
    PPErrorCodeUnknown NS_SWIFT_NAME(unknown) = 0,
    /// -[PPEmulator prepareWithUserDirectory:error:] was not called (or failed).
    PPErrorCodeNotPrepared NS_SWIFT_NAME(notPrepared) = 1,
    /// A game is already booting/running.
    PPErrorCodeAlreadyRunning NS_SWIFT_NAME(alreadyRunning) = 2,
    PPErrorCodeFileNotFound NS_SWIFT_NAME(fileNotFound) = 3,
    /// No loader for the file (ResultStatus::ErrorGetLoader / ErrorLoader_ErrorInvalidFormat).
    PPErrorCodeUnsupportedFormat NS_SWIFT_NAME(unsupportedFormat) = 4,
    /// The ROM is encrypted (ResultStatus::ErrorLoader_ErrorEncrypted). Azahar needs decrypted dumps.
    PPErrorCodeEncryptedROM NS_SWIFT_NAME(encryptedROM) = 5,
    /// A .cia was passed to startGame: it must be installed first.
    PPErrorCodeCIANeedsInstall NS_SWIFT_NAME(ciaNeedsInstall) = 6,
    /// New 3DS exclusive title while isNew3DS == NO (ResultStatus::ErrorN3DSApplication).
    PPErrorCodeNew3DSRequired NS_SWIFT_NAME(new3DSRequired) = 7,
    /// GBA Virtual Console title (ResultStatus::ErrorLoader_ErrorGbaTitle).
    PPErrorCodeGBAVirtualConsole NS_SWIFT_NAME(gbaVirtualConsole) = 8,
    /// ResultStatus::ErrorSystemMode.
    PPErrorCodeSystemMode NS_SWIFT_NAME(systemMode) = 9,
    /// ResultStatus::ErrorLoader and any other loader failure (patches, artic, unknown).
    PPErrorCodeLoaderFailed NS_SWIFT_NAME(loaderFailed) = 10,
    /// ResultStatus::ErrorSystemFiles (reported as non-fatal; emulation continues).
    PPErrorCodeSystemFilesMissing NS_SWIFT_NAME(systemFilesMissing) = 11,
    /// ResultStatus::ErrorSavestate / ErrorSavestateBuildMismatch (non-fatal).
    PPErrorCodeSaveStateFailed NS_SWIFT_NAME(saveStateFailed) = 12,
    /// ResultStatus::ErrorCoreExceptionRaised.
    PPErrorCodeCoreException NS_SWIFT_NAME(coreException) = 13,
    /// ResultStatus::ErrorShaderCacheCrash.
    PPErrorCodeShaderCacheCrash NS_SWIFT_NAME(shaderCacheCrash) = 14,
    /// A C++ exception escaped System::Load (typically Vulkan/MoltenVK initialisation failure).
    PPErrorCodeGraphicsInitFailed NS_SWIFT_NAME(graphicsInitFailed) = 15,
    /// Service::AM::InstallCIA did not return Success.
    PPErrorCodeCIAInstallFailed NS_SWIFT_NAME(ciaInstallFailed) = 16,
    PPErrorCodeInvalidArgument NS_SWIFT_NAME(invalidArgument) = 17,
    /// Operation only allowed while no game is running (console configuration).
    PPErrorCodeBusy NS_SWIFT_NAME(busy) = 18,
};

/// Emulated 3DS buttons. Raw values match Settings::NativeButton::Values exactly.
typedef NS_ENUM(NSInteger, PPButton) {
    PPButtonA NS_SWIFT_NAME(a) = 0,
    PPButtonB NS_SWIFT_NAME(b) = 1,
    PPButtonX NS_SWIFT_NAME(x) = 2,
    PPButtonY NS_SWIFT_NAME(y) = 3,
    PPButtonUp NS_SWIFT_NAME(up) = 4,
    PPButtonDown NS_SWIFT_NAME(down) = 5,
    PPButtonLeft NS_SWIFT_NAME(left) = 6,
    PPButtonRight NS_SWIFT_NAME(right) = 7,
    PPButtonL NS_SWIFT_NAME(l) = 8,
    PPButtonR NS_SWIFT_NAME(r) = 9,
    PPButtonStart NS_SWIFT_NAME(start) = 10,
    PPButtonSelect NS_SWIFT_NAME(select) = 11,
    PPButtonDebug NS_SWIFT_NAME(debug) = 12,
    PPButtonGpio14 NS_SWIFT_NAME(gpio14) = 13,
    PPButtonZL NS_SWIFT_NAME(zl) = 14,
    PPButtonZR NS_SWIFT_NAME(zr) = 15,
    PPButtonHome NS_SWIFT_NAME(home) = 16,
    PPButtonPower NS_SWIFT_NAME(power) = 17,
};

/// Raw values match Settings::NativeAnalog::Values.
typedef NS_ENUM(NSInteger, PPAnalogStick) {
    PPAnalogStickCirclePad NS_SWIFT_NAME(circlePad) = 0,
    PPAnalogStickCStick NS_SWIFT_NAME(cStick) = 1,
};

typedef NS_ENUM(NSInteger, PPEmulationState) {
    PPEmulationStateIdle NS_SWIFT_NAME(idle) = 0,
    /// Emulation thread started; System::Load in progress.
    PPEmulationStateBooting NS_SWIFT_NAME(booting) = 1,
    /// LoadDefaultDiskResources (disk shader cache) in progress.
    PPEmulationStateLoadingShaders NS_SWIFT_NAME(loadingShaders) = 2,
    PPEmulationStateRunning NS_SWIFT_NAME(running) = 3,
    PPEmulationStatePaused NS_SWIFT_NAME(paused) = 4,
    /// stop requested or the core ended; shutdown in progress.
    PPEmulationStateStopping NS_SWIFT_NAME(stopping) = 5,
};

/// Raw values match VideoCore::LoadCallbackStage.
typedef NS_ENUM(NSInteger, PPShaderLoadStage) {
    PPShaderLoadStagePrepare NS_SWIFT_NAME(prepare) = 0,
    PPShaderLoadStagePreload NS_SWIFT_NAME(preload) = 1,
    PPShaderLoadStageDecompile NS_SWIFT_NAME(decompile) = 2,
    PPShaderLoadStageBuild NS_SWIFT_NAME(build) = 3,
    PPShaderLoadStageComplete NS_SWIFT_NAME(complete) = 4,
};

/// Landscape screen layout. Raw values match Settings::LayoutOption on non-Android builds
/// (4 = SeparateWindows and 6 = CustomLayout are intentionally not exposed).
typedef NS_ENUM(NSInteger, PPScreenLayout) {
    PPScreenLayoutDefault NS_SWIFT_NAME(standard) = 0,
    PPScreenLayoutSingleScreen NS_SWIFT_NAME(singleScreen) = 1,
    PPScreenLayoutLargeScreen NS_SWIFT_NAME(largeScreen) = 2,
    PPScreenLayoutSideScreen NS_SWIFT_NAME(sideBySide) = 3,
    PPScreenLayoutHybridScreen NS_SWIFT_NAME(hybrid) = 5,
};

/// Raw values match Settings::PortraitLayoutOption (1 = PortraitCustomLayout not exposed).
typedef NS_ENUM(NSInteger, PPPortraitLayout) {
    PPPortraitLayoutTopFullWidth NS_SWIFT_NAME(topFullWidth) = 0,
    PPPortraitLayoutOriginal NS_SWIFT_NAME(original) = 2,
};

typedef NS_ENUM(NSInteger, PPCPUBackend) {
    /// JIT when +[PPEmulator JITAvailable] is YES at boot, otherwise the fast interpreter.
    PPCPUBackendAuto NS_SWIFT_NAME(automatic) = 0,
    /// Dynarmic + shader JIT. Silently downgraded to the interpreter (non-fatal warning) if JIT
    /// is not available at boot, because using it without JIT would crash.
    PPCPUBackendJIT NS_SWIFT_NAME(jit) = 1,
    /// FastInterp CPU + shader interpreter. Always safe, slower.
    PPCPUBackendInterpreter NS_SWIFT_NAME(interpreter) = 2,
};

/// Raw values match Settings::values.region_value.
typedef NS_ENUM(NSInteger, PPRegion) {
    PPRegionAuto NS_SWIFT_NAME(automatic) = -1,
    PPRegionJapan NS_SWIFT_NAME(japan) = 0,
    PPRegionUSA NS_SWIFT_NAME(usa) = 1,
    PPRegionEurope NS_SWIFT_NAME(europe) = 2,
    PPRegionAustralia NS_SWIFT_NAME(australia) = 3,
    PPRegionChina NS_SWIFT_NAME(china) = 4,
    PPRegionKorea NS_SWIFT_NAME(korea) = 5,
    PPRegionTaiwan NS_SWIFT_NAME(taiwan) = 6,
};

/// Raw values match Service::CFG::SystemLanguage.
typedef NS_ENUM(NSInteger, PPSystemLanguage) {
    PPSystemLanguageJapanese NS_SWIFT_NAME(japanese) = 0,
    PPSystemLanguageEnglish NS_SWIFT_NAME(english) = 1,
    PPSystemLanguageFrench NS_SWIFT_NAME(french) = 2,
    PPSystemLanguageGerman NS_SWIFT_NAME(german) = 3,
    PPSystemLanguageItalian NS_SWIFT_NAME(italian) = 4,
    PPSystemLanguageSpanish NS_SWIFT_NAME(spanish) = 5,
    PPSystemLanguageSimplifiedChinese NS_SWIFT_NAME(simplifiedChinese) = 6,
    PPSystemLanguageKorean NS_SWIFT_NAME(korean) = 7,
    PPSystemLanguageDutch NS_SWIFT_NAME(dutch) = 8,
    PPSystemLanguagePortuguese NS_SWIFT_NAME(portuguese) = 9,
    PPSystemLanguageRussian NS_SWIFT_NAME(russian) = 10,
    PPSystemLanguageTraditionalChinese NS_SWIFT_NAME(traditionalChinese) = 11,
};

/// Interface orientation used to rotate CoreMotion samples into the 3DS axis frame.
/// Raw values are the Android-style rotation index used by Azahar's motion code
/// (0 = portrait, 1 = landscapeRight [home indicator/button on the right], 2 = upside down,
/// 3 = landscapeLeft).
typedef NS_ENUM(NSInteger, PPInterfaceOrientation) {
    PPInterfaceOrientationPortrait NS_SWIFT_NAME(portrait) = 0,
    PPInterfaceOrientationLandscapeRight NS_SWIFT_NAME(landscapeRight) = 1,
    PPInterfaceOrientationPortraitUpsideDown NS_SWIFT_NAME(portraitUpsideDown) = 2,
    PPInterfaceOrientationLandscapeLeft NS_SWIFT_NAME(landscapeLeft) = 3,
};

NS_ASSUME_NONNULL_END
