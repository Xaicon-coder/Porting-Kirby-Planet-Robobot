// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.

#import "PPInternal.h"

NSErrorDomain const PPErrorDomain = @"PlanetCore.ErrorDomain";
NSString* const PPErrorCoreDetailsKey = @"PPErrorCoreDetails";

namespace PlanetPort {

NSString* ToNSString(const std::string& s) {
    if (s.empty()) {
        return @"";
    }
    NSString* result = [[NSString alloc] initWithBytes:s.data()
                                                length:s.size()
                                              encoding:NSUTF8StringEncoding];
    if (result == nil) {
        // Invalid UTF-8 (should not happen): fall back to a lossy conversion.
        result = [[NSString alloc] initWithBytes:s.data()
                                          length:s.size()
                                        encoding:NSISOLatin1StringEncoding];
    }
    return result ?: @"";
}

std::string ToStdString(NSString* _Nullable s) {
    if (s == nil || s.length == 0) {
        return {};
    }
    const char* utf8 = s.UTF8String;
    return utf8 != nullptr ? std::string(utf8) : std::string{};
}

NSError* MakeError(PPErrorCode code, NSString* message, const std::string& core_details) {
    NSMutableDictionary<NSErrorUserInfoKey, id>* info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message ?: @"Errore sconosciuto.";
    if (!core_details.empty()) {
        info[PPErrorCoreDetailsKey] = ToNSString(core_details);
    }
    return [NSError errorWithDomain:PPErrorDomain code:code userInfo:info];
}

void RunOnMain(dispatch_block_t block) {
    if (block == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), block);
}

} // namespace PlanetPort
