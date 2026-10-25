// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Console configuration (CFG), installed titles, CIA installation and save-state listing.

#include <algorithm>
#include <functional>
#include <string>
#include <vector>

#include "common/file_util.h"
#include "common/logging/log.h"
#include "common/string_util.h"
#include "core/core.h"
#include "core/hle/service/am/am.h"
#include "core/hle/service/cfg/cfg.h"
#include "core/loader/loader.h"
#include "core/savestate.h"

#import "PPInternal.h"

// -------------------------------------------------------------------------------------------
// PPSaveStateInfo
// -------------------------------------------------------------------------------------------

@implementation PPSaveStateInfo

- (instancetype)initWithSlot:(NSUInteger)slot date:(NSDate*)date compatible:(BOOL)compatible {
    if ((self = [super init])) {
        _slot = slot;
        _date = date;
        _compatible = compatible;
    }
    return self;
}

@end

namespace PlanetPort::Console {

namespace {

std::shared_ptr<Service::CFG::Module> CFGModule() {
    return Service::CFG::GetModule(Core::System::GetInstance());
}

bool Fail(NSError* _Nullable* _Nullable error, PPErrorCode code, NSString* message) {
    if (error) {
        *error = MakeError(code, message);
    }
    return false;
}

bool Persist(const std::shared_ptr<Service::CFG::Module>& cfg, NSError* _Nullable* _Nullable error) {
    const auto result = cfg->UpdateConfigNANDSavegame();
    if (result.IsError()) {
        LOG_ERROR(Frontend, "PlanetPort: UpdateConfigNANDSavegame failed");
        return Fail(error, PPErrorCodeUnknown,
                    @"Impossibile salvare la configurazione della console emulata.");
    }
    return true;
}

} // namespace

NSString* _Nullable GetConsoleUsername() {
    auto cfg = CFGModule();
    if (!cfg) {
        return nil;
    }
    const std::u16string name = cfg->GetUsername();
    std::size_t end = 0;
    while (end < name.size() && name[end] != u'\0') {
        ++end;
    }
    return ToNSString(Common::UTF16ToUTF8(std::u16string_view(name.data(), end)));
}

bool SetConsoleUsername(NSString* name, NSError* _Nullable* _Nullable error) {
    NSString* trimmed =
        [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    const std::u16string u16 = Common::UTF8ToUTF16(ToStdString(trimmed));
    if (u16.empty() || u16.size() > 10) {
        return Fail(error, PPErrorCodeInvalidArgument,
                    @"Il nome deve avere da 1 a 10 caratteri.");
    }
    auto cfg = CFGModule();
    if (!cfg) {
        return Fail(error, PPErrorCodeUnknown, @"Configurazione della console non disponibile.");
    }
    cfg->SetUsername(u16);
    return Persist(cfg, error);
}

PPSystemLanguage GetSystemLanguage() {
    auto cfg = CFGModule();
    if (!cfg) {
        return PPSystemLanguageEnglish;
    }
    const int language = static_cast<int>(cfg->GetSystemLanguage());
    if (language < 0 || language > static_cast<int>(PPSystemLanguageTraditionalChinese)) {
        return PPSystemLanguageEnglish;
    }
    return static_cast<PPSystemLanguage>(language);
}

bool SetSystemLanguage(PPSystemLanguage language, NSError* _Nullable* _Nullable error) {
    if (language < PPSystemLanguageJapanese || language > PPSystemLanguageTraditionalChinese) {
        return Fail(error, PPErrorCodeInvalidArgument, @"Lingua non valida.");
    }
    auto cfg = CFGModule();
    if (!cfg) {
        return Fail(error, PPErrorCodeUnknown, @"Configurazione della console non disponibile.");
    }
    cfg->SetSystemLanguage(static_cast<Service::CFG::SystemLanguage>(language));
    return Persist(cfg, error);
}

bool RegenerateConsoleID(NSError* _Nullable* _Nullable error) {
    auto cfg = CFGModule();
    if (!cfg) {
        return Fail(error, PPErrorCodeUnknown, @"Configurazione della console non disponibile.");
    }
    const auto [random_number, console_id] = cfg->GenerateConsoleUniqueId();
    const auto result = cfg->SetConsoleUniqueId(random_number, console_id);
    if (result.IsError()) {
        return Fail(error, PPErrorCodeUnknown, @"Impossibile generare un nuovo ID console.");
    }
    return Persist(cfg, error);
}

bool RegenerateMACAddress(NSError* _Nullable* _Nullable error) {
    auto cfg = CFGModule();
    if (!cfg) {
        return Fail(error, PPErrorCodeUnknown, @"Configurazione della console non disponibile.");
    }
    cfg->GetMacAddress() = Service::CFG::GenerateRandomMAC();
    cfg->SaveMacAddress();
    return true;
}

NSError* _Nullable InstallCIA(NSString* path,
                              const std::function<void(std::size_t, std::size_t)>& progress) {
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return MakeError(PPErrorCodeFileNotFound, @"Il file .cia non esiste.");
    }
    const std::string std_path = ToStdString(path);
    LOG_INFO(Frontend, "PlanetPort: installing CIA {}", std_path);

    const auto status = Service::AM::InstallCIA(
        std_path, [&progress](std::size_t written, std::size_t total) {
            if (progress) {
                progress(written, total);
            }
        });

    using Service::AM::InstallStatus;
    switch (status) {
    case InstallStatus::Success:
        return nil;
    case InstallStatus::ErrorEncrypted:
        return MakeError(PPErrorCodeEncryptedROM,
                         @"Il file .cia è criptato. Crealo decriptato con GodMode9 (\"Build CIA "
                         @"from file\" da un dump decriptato) e riprova.");
    case InstallStatus::ErrorFileNotFound:
    case InstallStatus::ErrorFailedToOpenFile:
        return MakeError(PPErrorCodeFileNotFound, @"Impossibile aprire il file .cia.");
    case InstallStatus::ErrorAborted:
        return MakeError(PPErrorCodeCIAInstallFailed, @"Installazione interrotta.");
    case InstallStatus::ErrorCannotCheckBundle:
        return MakeError(PPErrorCodeCIAInstallFailed,
                         @"Impossibile verificare il pacchetto .cia (bundle).");
    case InstallStatus::ErrorInvalid:
    default:
        return MakeError(PPErrorCodeCIAInstallFailed,
                         @"Il file .cia non è valido o è danneggiato.");
    }
}

NSArray<PPGameInfo*>* ScanInstalledTitles() {
    NSMutableArray<PPGameInfo*>* results = [NSMutableArray array];
    std::vector<std::string> executables;

    FileUtil::DirectoryEntryCallable scan_dir;
    scan_dir = [&executables, &scan_dir](u64*, const std::string& directory,
                                         const std::string& virtual_name) -> bool {
        std::string path = directory + virtual_name;
        if (FileUtil::IsDirectory(path)) {
            path += '/';
            FileUtil::ForeachDirectoryEntry(nullptr, path, scan_dir);
            return true;
        }
        if (!FileUtil::Exists(path)) {
            return true;
        }
        auto loader = Loader::GetLoader(path);
        if (loader) {
            bool executable = false;
            if (loader->IsExecutable(executable) == Loader::ResultStatus::Success && executable) {
                executables.push_back(path);
            }
        }
        return true;
    };

    const std::string sdmc_titles =
        FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir) +
        "Nintendo 3DS/00000000000000000000000000000000/00000000000000000000000000000000/title/"
        "00040000/";
    const std::string nand_titles = FileUtil::GetUserPath(FileUtil::UserPath::NANDDir) +
                                    "00000000000000000000000000000000/title/00040010/";
    for (const auto& root : {sdmc_titles, nand_titles}) {
        if (FileUtil::IsDirectory(root)) {
            FileUtil::ForeachDirectoryEntry(nullptr, root, scan_dir);
        }
    }

    for (const auto& path : executables) {
        PPGameInfo* info = [PPGameInfo installedGameInfoAtPath:ToNSString(path)];
        if (info != nil) {
            [results addObject:info];
        }
    }
    return results;
}

NSArray<PPSaveStateInfo*>* ListSaveStates(std::uint64_t title_id) {
    std::vector<Core::SaveStateInfo> states = Core::ListSaveStates(title_id, 0);
    std::sort(states.begin(), states.end(),
              [](const auto& a, const auto& b) { return a.slot < b.slot; });
    NSMutableArray<PPSaveStateInfo*>* results = [NSMutableArray array];
    for (const auto& state : states) {
        NSDate* date = state.time != 0
                           ? [NSDate dateWithTimeIntervalSince1970:static_cast<double>(state.time)]
                           : nil;
        const BOOL compatible =
            state.status == Core::SaveStateInfo::ValidationStatus::OK ? YES : NO;
        [results addObject:[[PPSaveStateInfo alloc] initWithSlot:state.slot
                                                            date:date
                                                      compatible:compatible]];
    }
    return results;
}

} // namespace PlanetPort::Console
