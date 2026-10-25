// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Metadata read from a game file (SMDH title, publisher, icon, title id) without booting it.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PlanetCore/PPTypes.h>

NS_ASSUME_NONNULL_BEGIN

@interface PPGameInfo : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Reads metadata for a bootable file (.3ds .cci .cxi .app .3dsx .elf and the z/b variants) or a
/// .cia (through Service::AM::GetCIAInfos, without installing it).
/// Requires -[PPEmulator prepareWithUserDirectory:error:]. Thread-safe; may be slow (file I/O),
/// so call it off the main thread for big files.
/// Returns nil + error (PPErrorCodeFileNotFound / PPErrorCodeUnsupportedFormat) only when the file
/// cannot be identified at all. Encrypted files still return an object with isEncrypted == YES.
+ (nullable PPGameInfo *)gameInfoAtPath:(NSString *)path error:(NSError **)error;

@property (nonatomic, readonly, copy) NSString *path;
/// Long title in the device language when present in the SMDH, else English long title, else
/// the short title, else the file name without extension.
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *shortTitle;
/// Empty string when unknown.
@property (nonatomic, readonly, copy) NSString *publisher;
/// Program id, 0 when unknown (3DSX/ELF).
@property (nonatomic, readonly) uint64_t titleID;
/// "%016llX" of titleID.
@property (nonatomic, readonly, copy) NSString *titleIDString;
/// 48x48 icon decoded from the SMDH (RGB565 -> RGBA), nil when missing.
@property (nonatomic, readonly, nullable) UIImage *icon;
/// Loader::GetFileTypeString(...) for bootable files, "CIA" for .cia.
@property (nonatomic, readonly, copy) NSString *fileTypeDescription;
/// YES for .cia/.zcia/.bcia: must be installed with -[PPEmulator installCIAAtPath:...] first.
@property (nonatomic, readonly) BOOL isCIA;
/// YES when the loader reported ErrorEncrypted (cannot be booted by Azahar).
@property (nonatomic, readonly) BOOL isEncrypted;
/// YES when the path lives inside the emulated SD card / NAND title folders (installed title).
@property (nonatomic, readonly) BOOL isInstalledTitle;
/// Heuristic: any SMDH title (any language) or the file name contains "Robobot" (case
/// insensitive) or "ロボボ". Used by the app to highlight Kirby: Planet Robobot.
@property (nonatomic, readonly) BOOL looksLikePlanetRobobot;
/// Human readable region names from the SMDH (e.g. "Europa", "Nord America"), may be empty.
@property (nonatomic, readonly, copy) NSArray<NSString *> *regions;

@end

NS_ASSUME_NONNULL_END
