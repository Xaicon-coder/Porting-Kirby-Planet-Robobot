// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Game metadata without booting. Follows the Android frontend's game_info.cpp.

#include <algorithm>
#include <cstring>
#include <memory>
#include <span>
#include <string>
#include <vector>

#include "common/file_util.h"
#include "common/logging/log.h"
#include "common/string_util.h"
#include "core/hle/service/am/am.h"
#include "core/loader/loader.h"
#include "core/loader/smdh.h"

#import <UIKit/UIKit.h>

#import "PPInternal.h"

using namespace PlanetPort;

namespace {

constexpr std::size_t kIconSize = 48;

std::string TrimUTF16(const char16_t* data, std::size_t length) {
    std::size_t end = 0;
    while (end < length && data[end] != u'\0') {
        ++end;
    }
    std::string utf8 = Common::UTF16ToUTF8(std::u16string_view(data, end));
    // Trim surrounding whitespace / newlines (some SMDH titles contain '\n').
    const auto first = utf8.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return {};
    }
    const auto last = utf8.find_last_not_of(" \t\r\n");
    std::string trimmed = utf8.substr(first, last - first + 1);
    std::replace(trimmed.begin(), trimmed.end(), '\n', ' ');
    return trimmed;
}

Loader::SMDH::TitleLanguage PreferredTitleLanguage() {
    NSString* preferred = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"en";
    if ([preferred hasPrefix:@"it"]) return Loader::SMDH::TitleLanguage::Italian;
    if ([preferred hasPrefix:@"fr"]) return Loader::SMDH::TitleLanguage::French;
    if ([preferred hasPrefix:@"de"]) return Loader::SMDH::TitleLanguage::German;
    if ([preferred hasPrefix:@"es"]) return Loader::SMDH::TitleLanguage::Spanish;
    if ([preferred hasPrefix:@"ja"]) return Loader::SMDH::TitleLanguage::Japanese;
    if ([preferred hasPrefix:@"ko"]) return Loader::SMDH::TitleLanguage::Korean;
    if ([preferred hasPrefix:@"nl"]) return Loader::SMDH::TitleLanguage::Dutch;
    if ([preferred hasPrefix:@"pt"]) return Loader::SMDH::TitleLanguage::Portuguese;
    if ([preferred hasPrefix:@"ru"]) return Loader::SMDH::TitleLanguage::Russian;
    if ([preferred hasPrefix:@"zh-hant"] || [preferred hasPrefix:@"zh-tw"] ||
        [preferred hasPrefix:@"zh-hk"]) {
        return Loader::SMDH::TitleLanguage::TraditionalChinese;
    }
    if ([preferred hasPrefix:@"zh"]) return Loader::SMDH::TitleLanguage::SimplifiedChinese;
    return Loader::SMDH::TitleLanguage::English;
}

std::string LongTitle(const Loader::SMDH& smdh, Loader::SMDH::TitleLanguage language) {
    const auto title = smdh.GetLongTitle(language);
    return TrimUTF16(title.data(), title.size());
}

std::string ShortTitle(const Loader::SMDH& smdh, Loader::SMDH::TitleLanguage language) {
    const auto title = smdh.GetShortTitle(language);
    return TrimUTF16(title.data(), title.size());
}

std::string Publisher(const Loader::SMDH& smdh, Loader::SMDH::TitleLanguage language) {
    const auto& entry = smdh.titles[static_cast<std::size_t>(language)];
    std::string publisher = TrimUTF16(entry.publisher.data(), entry.publisher.size());
    if (publisher.empty()) {
        const auto& english =
            smdh.titles[static_cast<std::size_t>(Loader::SMDH::TitleLanguage::English)];
        publisher = TrimUTF16(english.publisher.data(), english.publisher.size());
    }
    return publisher;
}

UIImage* _Nullable IconFromSMDH(const Loader::SMDH& smdh) {
    const std::vector<u16> pixels = smdh.GetIcon(true);
    if (pixels.size() < kIconSize * kIconSize) {
        return nil;
    }
    std::vector<u8> rgba(kIconSize * kIconSize * 4);
    for (std::size_t i = 0; i < kIconSize * kIconSize; ++i) {
        const u16 value = pixels[i];
        const u8 r5 = (value >> 11) & 0x1F;
        const u8 g6 = (value >> 5) & 0x3F;
        const u8 b5 = value & 0x1F;
        rgba[i * 4 + 0] = static_cast<u8>((r5 << 3) | (r5 >> 2));
        rgba[i * 4 + 1] = static_cast<u8>((g6 << 2) | (g6 >> 4));
        rgba[i * 4 + 2] = static_cast<u8>((b5 << 3) | (b5 >> 2));
        rgba[i * 4 + 3] = 0xFF;
    }
    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, rgba.data(), static_cast<CFIndex>(rgba.size()));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGImageRef image = CGImageCreate(kIconSize, kIconSize, 8, 32, kIconSize * 4, color_space,
                                     kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
                                     provider, nullptr, false, kCGRenderingIntentDefault);
    UIImage* result = image != nullptr ? [UIImage imageWithCGImage:image] : nil;
    if (image != nullptr) {
        CGImageRelease(image);
    }
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(color_space);
    return result;
}

NSArray<NSString*>* RegionNames(const Loader::SMDH& smdh) {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (const auto region : smdh.GetRegions()) {
        NSString* name = nil;
        switch (region) {
        case Loader::SMDH::GameRegion::Japan:
            name = @"Giappone";
            break;
        case Loader::SMDH::GameRegion::NorthAmerica:
            name = @"Nord America";
            break;
        case Loader::SMDH::GameRegion::Europe:
            name = @"Europa";
            break;
        case Loader::SMDH::GameRegion::Australia:
            name = @"Australia";
            break;
        case Loader::SMDH::GameRegion::China:
            name = @"Cina";
            break;
        case Loader::SMDH::GameRegion::Korea:
            name = @"Corea";
            break;
        case Loader::SMDH::GameRegion::Taiwan:
            name = @"Taiwan";
            break;
        }
        if (name != nil && ![names containsObject:name]) {
            [names addObject:name];
        }
    }
    return names;
}

bool ContainsRobobot(const std::string& text) {
    if (text.empty()) {
        return false;
    }
    NSString* string = ToNSString(text);
    return [string rangeOfString:@"robobot" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [string rangeOfString:@"ロボボ"].location != NSNotFound;
}

bool SMDHMentionsRobobot(const Loader::SMDH& smdh) {
    for (const auto& entry : smdh.titles) {
        if (ContainsRobobot(TrimUTF16(entry.long_title.data(), entry.long_title.size())) ||
            ContainsRobobot(TrimUTF16(entry.short_title.data(), entry.short_title.size()))) {
            return true;
        }
    }
    return false;
}

bool IsCIAExtension(NSString* path) {
    NSString* ext = path.pathExtension.lowercaseString;
    return [ext isEqualToString:@"cia"] || [ext isEqualToString:@"zcia"] ||
           [ext isEqualToString:@"bcia"];
}

bool PathIsInside(const std::string& path, const std::string& directory) {
    return !directory.empty() && path.size() > directory.size() &&
           path.compare(0, directory.size(), directory) == 0;
}

} // namespace

@interface PPGameInfo ()
@property (nonatomic, readwrite, copy) NSString* path;
@property (nonatomic, readwrite, copy) NSString* title;
@property (nonatomic, readwrite, copy) NSString* shortTitle;
@property (nonatomic, readwrite, copy) NSString* publisher;
@property (nonatomic, readwrite) uint64_t titleID;
@property (nonatomic, readwrite, copy) NSString* titleIDString;
@property (nonatomic, readwrite, nullable) UIImage* icon;
@property (nonatomic, readwrite, copy) NSString* fileTypeDescription;
@property (nonatomic, readwrite) BOOL isCIA;
@property (nonatomic, readwrite) BOOL isEncrypted;
@property (nonatomic, readwrite) BOOL isInstalledTitle;
@property (nonatomic, readwrite) BOOL looksLikePlanetRobobot;
@property (nonatomic, readwrite, copy) NSArray<NSString*>* regions;
- (instancetype)initEmpty;
@end

@implementation PPGameInfo

- (instancetype)initEmpty {
    if ((self = [super init])) {
        _path = @"";
        _title = @"";
        _shortTitle = @"";
        _publisher = @"";
        _titleIDString = @"0000000000000000";
        _fileTypeDescription = @"";
        _regions = @[];
    }
    return self;
}

- (void)applySMDH:(const Loader::SMDH&)smdh fileName:(NSString*)fileName {
    const auto preferred = PreferredTitleLanguage();
    std::string long_title = LongTitle(smdh, preferred);
    if (long_title.empty()) {
        long_title = LongTitle(smdh, Loader::SMDH::TitleLanguage::English);
    }
    std::string short_title = ShortTitle(smdh, preferred);
    if (short_title.empty()) {
        short_title = ShortTitle(smdh, Loader::SMDH::TitleLanguage::English);
    }
    NSString* title = ToNSString(!long_title.empty() ? long_title : short_title);
    self.title = title.length > 0 ? title : fileName;
    self.shortTitle = short_title.empty() ? self.title : ToNSString(short_title);
    self.publisher = ToNSString(Publisher(smdh, preferred));
    self.icon = IconFromSMDH(smdh);
    self.regions = RegionNames(smdh);
    self.looksLikePlanetRobobot = SMDHMentionsRobobot(smdh) ? YES : NO;
}

+ (nullable PPGameInfo*)gameInfoAtPath:(NSString*)path error:(NSError**)error {
    if (!IsPrepared()) {
        if (error) {
            *error = MakeError(PPErrorCodeNotPrepared, @"Il core non è stato inizializzato.");
        }
        return nil;
    }
    BOOL is_directory = NO;
    if (path.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&is_directory] ||
        is_directory) {
        if (error) {
            *error = MakeError(PPErrorCodeFileNotFound, @"Il file non esiste.");
        }
        return nil;
    }

    const std::string std_path = ToStdString(path);
    NSString* file_name = path.lastPathComponent.stringByDeletingPathExtension;

    PPGameInfo* info = [[PPGameInfo alloc] initEmpty];
    info.path = path;
    info.title = file_name;
    info.shortTitle = file_name;
    info.isInstalledTitle =
        (PathIsInside(std_path, FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir)) ||
         PathIsInside(std_path, FileUtil::GetUserPath(FileUtil::UserPath::NANDDir)))
            ? YES
            : NO;

    if (IsCIAExtension(path)) {
        info.isCIA = YES;
        info.fileTypeDescription = @"CIA";
        auto cia = Service::AM::GetCIAInfos(std_path);
        if (cia.Succeeded()) {
            auto& value = cia.Unwrap();
            info.titleID = value.first.tid;
            if (value.second && value.second->IsValid()) {
                [info applySMDH:*value.second fileName:file_name];
            }
        } else {
            // Most likely encrypted or damaged; installation will report the precise reason.
            LOG_WARNING(Frontend, "PlanetPort: GetCIAInfos failed for {}", std_path);
        }
    } else {
        std::unique_ptr<Loader::AppLoader> loader = Loader::GetLoader(std_path);
        if (!loader) {
            if (error) {
                *error = MakeError(PPErrorCodeUnsupportedFormat,
                                   @"Formato del file non riconosciuto.");
            }
            return nil;
        }
        info.fileTypeDescription = ToNSString(Loader::GetFileTypeString(
            loader->GetFileType(), loader->IsFileCompressed(), loader->IsFileBundle()));

        u64 program_id = 0;
        const auto id_result = loader->ReadProgramId(program_id);
        if (id_result == Loader::ResultStatus::ErrorEncrypted) {
            info.isEncrypted = YES;
        } else if (id_result != Loader::ResultStatus::Success) {
            program_id = 0; // 3DSX / ELF have no program id.
        }
        info.titleID = program_id;

        std::vector<u8> smdh_buffer;
        const auto icon_result = loader->ReadIcon(smdh_buffer, true);
        if (icon_result == Loader::ResultStatus::ErrorEncrypted) {
            info.isEncrypted = YES;
        } else if (icon_result == Loader::ResultStatus::Success &&
                   smdh_buffer.size() >= sizeof(Loader::SMDH) &&
                   Loader::IsValidSMDH(std::span<const u8>(smdh_buffer.data(), smdh_buffer.size()))) {
            Loader::SMDH smdh{};
            std::memcpy(&smdh, smdh_buffer.data(), sizeof(Loader::SMDH));
            [info applySMDH:smdh fileName:file_name];
        }
    }

    info.titleIDString = [NSString stringWithFormat:@"%016llX", info.titleID];
    if (!info.looksLikePlanetRobobot && ContainsRobobot(ToStdString(file_name))) {
        info.looksLikePlanetRobobot = YES;
    }
    return info;
}

+ (nullable PPGameInfo*)installedGameInfoAtPath:(NSString*)path {
    PPGameInfo* info = [self gameInfoAtPath:path error:nil];
    if (info != nil) {
        info.isInstalledTitle = YES;
    }
    return info;
}

@end
