// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Multiplayer rooms. Port of the Android frontend's multiplayer.cpp with the Qt frontend's
// hosting approach (bind all interfaces, join through 127.0.0.1 with the console MAC).

#include <algorithm>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <thread>
#include <vector>

#include "common/logging/log.h"
#include "core/core.h"
#include "core/hle/service/cfg/cfg.h"
#include "network/network.h"
#include "network/room.h"
#include "network/room_member.h"
#include "network/verify_user.h"

#import <PlanetCore/PPMultiplayer.h>

#import "PPInternal.h"

const uint16_t PPDefaultRoomPort = Network::DefaultRoomPort;

// -------------------------------------------------------------------------------------------
// Value classes
// -------------------------------------------------------------------------------------------

@interface PPNetEvent ()
- (instancetype)initWithStatus:(PPNetStatus)status
                      nickname:(nullable NSString*)nickname
                       message:(nullable NSString*)message
                     localEcho:(BOOL)localEcho;
@end

@implementation PPNetEvent

- (instancetype)initWithStatus:(PPNetStatus)status
                      nickname:(NSString*)nickname
                       message:(NSString*)message
                     localEcho:(BOOL)localEcho {
    if ((self = [super init])) {
        _status = status;
        _nickname = [nickname copy];
        _message = [message copy];
        _isLocalEcho = localEcho;
    }
    return self;
}

@end

@interface PPRoomMember ()
- (instancetype)initWithInfo:(const Network::RoomMember::MemberInformation&)info;
@end

@implementation PPRoomMember

- (instancetype)initWithInfo:(const Network::RoomMember::MemberInformation&)info {
    if ((self = [super init])) {
        _nickname = PlanetPort::ToNSString(info.nickname);
        _username = PlanetPort::ToNSString(info.username);
        _gameName = PlanetPort::ToNSString(info.game_info.name);
        _gameID = info.game_info.id;
        const auto& mac = info.mac_address;
        _macAddress = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1],
                                                 mac[2], mac[3], mac[4], mac[5]];
    }
    return self;
}

@end

@interface PPRoomInfo ()
- (instancetype)initWithInfo:(const Network::RoomInformation&)info;
@end

@implementation PPRoomInfo

- (instancetype)initWithInfo:(const Network::RoomInformation&)info {
    if ((self = [super init])) {
        _name = PlanetPort::ToNSString(info.name);
        _roomDescription = PlanetPort::ToNSString(info.description);
        _memberSlots = info.member_slots;
        _port = info.port;
        _preferredGame = PlanetPort::ToNSString(info.preferred_game);
        _hostUsername = PlanetPort::ToNSString(info.host_username);
    }
    return self;
}

@end

// -------------------------------------------------------------------------------------------
// Internal state
// -------------------------------------------------------------------------------------------

namespace {

using Network::RoomMember;

std::mutex g_cache_mutex;
NSArray<PPRoomMember*>* g_members = @[]; // guarded by g_cache_mutex
PPRoomInfo* g_room_info = nil;           // guarded by g_cache_mutex

std::atomic_bool g_activated{false};
/// Last RoomMember::Error received (as PPNetStatus), -1 when none since the last reset.
std::atomic<int> g_last_error{-1};

RoomMember::CallbackHandle<RoomMember::State> g_state_handle;
RoomMember::CallbackHandle<RoomMember::Error> g_error_handle;
RoomMember::CallbackHandle<Network::StatusMessageEntry> g_status_handle;
RoomMember::CallbackHandle<Network::ChatEntry> g_chat_handle;
RoomMember::CallbackHandle<Network::RoomInformation> g_info_handle;

dispatch_queue_t NetworkQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("org.planetport.multiplayer", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

PPNetStatus StatusForError(RoomMember::Error error) {
    switch (error) {
    case RoomMember::Error::LostConnection:
        return PPNetStatusLostConnection;
    case RoomMember::Error::HostKicked:
        return PPNetStatusHostKicked;
    case RoomMember::Error::UnknownError:
        return PPNetStatusUnknownError;
    case RoomMember::Error::NameCollision:
        return PPNetStatusNameCollision;
    case RoomMember::Error::MacCollision:
        return PPNetStatusMacCollision;
    case RoomMember::Error::ConsoleIdCollision:
        return PPNetStatusConsoleIdCollision;
    case RoomMember::Error::WrongVersion:
        return PPNetStatusWrongVersion;
    case RoomMember::Error::WrongPassword:
        return PPNetStatusWrongPassword;
    case RoomMember::Error::CouldNotConnect:
        return PPNetStatusCouldNotConnect;
    case RoomMember::Error::RoomIsFull:
        return PPNetStatusRoomIsFull;
    case RoomMember::Error::HostBanned:
        return PPNetStatusHostBanned;
    case RoomMember::Error::PermissionDenied:
        return PPNetStatusPermissionDenied;
    case RoomMember::Error::NoSuchUser:
        return PPNetStatusNoSuchUser;
    }
    return PPNetStatusUnknownError;
}

void DeliverEvent(PPNetStatus status, NSString* _Nullable nickname, NSString* _Nullable message,
                  BOOL local_echo = NO) {
    PPNetEvent* event = [[PPNetEvent alloc] initWithStatus:status
                                                  nickname:nickname
                                                   message:message
                                                 localEcho:local_echo];
    PlanetPort::RunOnMain(^{
        PPMultiplayer* multiplayer = PPMultiplayer.sharedMultiplayer;
        [multiplayer.delegate multiplayer:multiplayer didReceiveEvent:event];
    });
}

void DeliverRoomChanged() {
    PlanetPort::RunOnMain(^{
        PPMultiplayer* multiplayer = PPMultiplayer.sharedMultiplayer;
        id<PPMultiplayerDelegate> delegate = multiplayer.delegate;
        if ([delegate respondsToSelector:@selector(multiplayerRoomDidChange:)]) {
            [delegate multiplayerRoomDidChange:multiplayer];
        }
    });
}

bool IsJoinedState(RoomMember::State state) {
    return state == RoomMember::State::Joined || state == RoomMember::State::Moderator;
}

/// Refreshes the cached room info / member list. Must run on the RoomMember loop thread (inside
/// a callback) or while no connection exists, because GetMemberInformation() returns a reference
/// that the loop thread mutates without a lock.
void RefreshCache(const std::shared_ptr<RoomMember>& member) {
    NSMutableArray<PPRoomMember*>* members = [NSMutableArray array];
    PPRoomInfo* info = nil;
    if (member && IsJoinedState(member->GetState())) {
        const RoomMember::MemberList list = member->GetMemberInformation(); // copy
        for (const auto& entry : list) {
            [members addObject:[[PPRoomMember alloc] initWithInfo:entry]];
        }
        info = [[PPRoomInfo alloc] initWithInfo:member->GetRoomInformation()];
    }
    std::scoped_lock lock{g_cache_mutex};
    g_members = [members copy];
    g_room_info = info;
}

void ClearCache() {
    std::scoped_lock lock{g_cache_mutex};
    g_members = @[];
    g_room_info = nil;
}

std::string ConsoleNickname() {
    return Service::CFG::GetUsername(Core::System::GetInstance());
}

bool MatchesPattern(NSString* text, NSString* pattern) {
    if (text == nil) {
        return false;
    }
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:0
                                                                             error:nil];
    if (regex == nil) {
        return false;
    }
    const NSRange range = NSMakeRange(0, text.length);
    NSTextCheckingResult* match = [regex firstMatchInString:text options:0 range:range];
    return match != nil && NSEqualRanges(match.range, range);
}

/// Waits (polling) until the member is Joined/Moderator, an error arrives or `timeout` expires.
PPNetStatus WaitForJoin(const std::shared_ptr<RoomMember>& member,
                        std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (IsJoinedState(member->GetState())) {
            return PPNetStatusNoError;
        }
        const int error = g_last_error.load();
        if (error >= 0) {
            return static_cast<PPNetStatus>(error);
        }
        if (member->GetState() == RoomMember::State::Idle && !member->IsConnected()) {
            // Join() reports early failures synchronously through OnError; give it a moment.
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            const int late_error = g_last_error.load();
            return late_error >= 0 ? static_cast<PPNetStatus>(late_error)
                                   : PPNetStatusCouldNotConnect;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (IsJoinedState(member->GetState())) {
        return PPNetStatusNoError;
    }
    const int error = g_last_error.load();
    return error >= 0 ? static_cast<PPNetStatus>(error) : PPNetStatusCouldNotConnect;
}

void LeaveAndDestroy() {
    if (auto member = Network::GetRoomMember().lock()) {
        // Leave() dereferences its loop thread unconditionally: only call it when connected.
        if (member->IsConnected()) {
            member->Leave();
        }
    }
    if (auto room = Network::GetRoom().lock()) {
        // Destroy() dereferences the room thread: only when the room is open.
        if (room->GetState() == Network::Room::State::Open) {
            room->Destroy();
        }
    }
    ClearCache();
}

} // namespace

// -------------------------------------------------------------------------------------------
// PPMultiplayer
// -------------------------------------------------------------------------------------------

@implementation PPMultiplayer

+ (PPMultiplayer*)sharedMultiplayer {
    static PPMultiplayer* shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[PPMultiplayer alloc] initPrivate];
    });
    return shared;
}

- (instancetype)initPrivate {
    return [super init];
}

- (BOOL)activate {
    if (g_activated.load()) {
        return YES;
    }
    if (!PlanetPort::IsPrepared()) {
        return NO;
    }
    auto member = Network::GetRoomMember().lock();
    if (!member) {
        return NO;
    }
    if (g_activated.exchange(true)) {
        return YES;
    }

    // Callbacks run on the RoomMember loop thread while it holds its callback mutex: never
    // Bind/Unbind/Leave from inside them; copy what is needed and hop to the main queue.
    std::weak_ptr<RoomMember> weak_member = member;

    // Azahar's loop thread is a plain std::thread without an autorelease pool: every callback
    // drains its own pool so Objective-C temporaries do not accumulate for the whole session.
    g_state_handle = member->BindOnStateChanged([weak_member](const RoomMember::State& state) {
        @autoreleasepool {
            if (state == RoomMember::State::Joined) {
                DeliverEvent(PPNetStatusRoomJoined, nil, nil);
            } else if (state == RoomMember::State::Moderator) {
                DeliverEvent(PPNetStatusRoomModerator, nil, nil);
            } else if (state == RoomMember::State::Idle) {
                ClearCache();
            }
            if (IsJoinedState(state)) {
                RefreshCache(weak_member.lock());
            }
            DeliverRoomChanged();
        }
    });

    g_error_handle = member->BindOnError([](const RoomMember::Error& error) {
        @autoreleasepool {
            const PPNetStatus status = StatusForError(error);
            g_last_error = static_cast<int>(status);
            DeliverEvent(status, nil, nil);
        }
    });

    g_status_handle =
        member->BindOnStatusMessageReceived([weak_member](const Network::StatusMessageEntry& entry) {
            PPNetStatus status = PPNetStatusUnknownError;
            switch (entry.type) {
            case Network::IdMemberJoin:
                status = PPNetStatusMemberJoin;
                break;
            case Network::IdMemberLeave:
                status = PPNetStatusMemberLeave;
                break;
            case Network::IdMemberKicked:
                status = PPNetStatusMemberKicked;
                break;
            case Network::IdMemberBanned:
                status = PPNetStatusMemberBanned;
                break;
            case Network::IdAddressUnbanned:
                status = PPNetStatusAddressUnbanned;
                break;
            default:
                return;
            }
            @autoreleasepool {
                NSString* nickname = PlanetPort::ToNSString(entry.nickname);
                DeliverEvent(status, nickname,
                             status == PPNetStatusAddressUnbanned ? nickname : nil);
                RefreshCache(weak_member.lock());
                DeliverRoomChanged();
            }
        });

    g_chat_handle = member->BindOnChatMessageRecieved([](const Network::ChatEntry& entry) {
        @autoreleasepool {
            DeliverEvent(PPNetStatusChatMessage, PlanetPort::ToNSString(entry.nickname),
                         PlanetPort::ToNSString(entry.message));
        }
    });

    g_info_handle =
        member->BindOnRoomInformationChanged([weak_member](const Network::RoomInformation&) {
            @autoreleasepool {
                RefreshCache(weak_member.lock());
                DeliverRoomChanged();
            }
        });

    LOG_INFO(Frontend, "PlanetPort: multiplayer callbacks bound");
    return YES;
}

#pragma mark Snapshots

- (BOOL)isJoined {
    auto member = Network::GetRoomMember().lock();
    return member && IsJoinedState(member->GetState()) ? YES : NO;
}

- (BOOL)isHosting {
    auto room = Network::GetRoom().lock();
    return room && room->GetState() == Network::Room::State::Open ? YES : NO;
}

- (BOOL)isModerator {
    auto member = Network::GetRoomMember().lock();
    return member && member->GetState() == RoomMember::State::Moderator ? YES : NO;
}

- (PPRoomInfo*)roomInfo {
    std::scoped_lock lock{g_cache_mutex};
    return g_room_info;
}

- (NSArray<PPRoomMember*>*)members {
    std::scoped_lock lock{g_cache_mutex};
    return g_members;
}

#pragma mark Validation

+ (BOOL)isValidNickname:(NSString*)nickname {
    return MatchesPattern(nickname, @"^[ a-zA-Z0-9._-]{4,10}$") ? YES : NO;
}

+ (BOOL)isValidRoomName:(NSString*)name {
    return MatchesPattern(name, @"^[ a-zA-Z0-9._-]{4,20}$") ? YES : NO;
}

+ (NSString*)descriptionForStatus:(PPNetStatus)status {
    switch (status) {
    case PPNetStatusNoError:
        return @"Operazione completata.";
    case PPNetStatusNetworkError:
        return @"La rete non è disponibile.";
    case PPNetStatusLostConnection:
        return @"Connessione alla stanza persa.";
    case PPNetStatusNameCollision:
        return @"Il tuo nome è già usato da un altro giocatore nella stanza. Cambialo e riprova.";
    case PPNetStatusMacCollision:
        return @"Un altro giocatore ha lo stesso indirizzo MAC. Vai in Impostazioni > Console e "
               @"tocca \"Rigenera indirizzo MAC\".";
    case PPNetStatusConsoleIdCollision:
        return @"Un altro giocatore ha lo stesso ID console. Vai in Impostazioni > Console e tocca "
               @"\"Rigenera ID console\".";
    case PPNetStatusWrongVersion:
        return @"La stanza usa una versione diversa del protocollo di rete.";
    case PPNetStatusWrongPassword:
        return @"Password errata.";
    case PPNetStatusCouldNotConnect:
        return @"Impossibile connettersi alla stanza. Controlla indirizzo e porta, che siate sulla "
               @"stessa rete Wi-Fi oppure che chi ospita abbia aperto la porta UDP 24872 (o usate "
               @"una VPN come Tailscale o ZeroTier).";
    case PPNetStatusRoomIsFull:
        return @"La stanza è piena.";
    case PPNetStatusHostBanned:
        return @"Sei stato bandito da questa stanza.";
    case PPNetStatusPermissionDenied:
        return @"Non hai i permessi per questa operazione.";
    case PPNetStatusNoSuchUser:
        return @"Giocatore non trovato.";
    case PPNetStatusAlreadyInRoom:
        return @"Sei già in una stanza.";
    case PPNetStatusCreateRoomError:
        return @"Impossibile creare la stanza. Il nome deve avere da 4 a 20 caratteri (lettere, "
               @"numeri, spazi, . _ -) e la porta deve essere libera.";
    case PPNetStatusHostKicked:
        return @"Sei stato espulso dalla stanza.";
    case PPNetStatusUnknownError:
        return @"Errore di rete sconosciuto.";
    case PPNetStatusRoomUninitialized:
        return @"Multiplayer non inizializzato.";
    case PPNetStatusRoomIdle:
        return @"Non sei in nessuna stanza.";
    case PPNetStatusRoomJoining:
        return @"Connessione alla stanza…";
    case PPNetStatusRoomJoined:
        return @"Sei entrato nella stanza.";
    case PPNetStatusRoomModerator:
        return @"Sei entrato nella stanza come moderatore.";
    case PPNetStatusMemberJoin:
        return @"è entrato nella stanza.";
    case PPNetStatusMemberLeave:
        return @"ha lasciato la stanza.";
    case PPNetStatusMemberKicked:
        return @"è stato espulso.";
    case PPNetStatusMemberBanned:
        return @"è stato bandito.";
    case PPNetStatusAddressUnbanned:
        return @"Indirizzo sbloccato.";
    case PPNetStatusChatMessage:
        return @"Messaggio";
    }
    return @"Errore di rete sconosciuto.";
}

#pragma mark Host / join / leave

- (void)hostRoomNamed:(NSString*)name
                 port:(uint16_t)port
             password:(NSString*)password
           maxPlayers:(NSUInteger)maxPlayers
    preferredGameName:(NSString*)preferredGameName
      preferredGameID:(uint64_t)preferredGameID
           completion:(void (^)(PPNetStatus))completion {
    NSString* nameCopy = [name copy];
    NSString* passwordCopy = [password copy] ?: @"";
    NSString* gameCopy = [preferredGameName copy] ?: @"";
    void (^done)(PPNetStatus) = ^(PPNetStatus status) {
        PlanetPort::RunOnMain(^{
            if (completion) {
                completion(status);
            }
        });
    };

    dispatch_async(NetworkQueue(), ^{
        if (!g_activated.load()) {
            done(PPNetStatusRoomUninitialized);
            return;
        }
        auto member = Network::GetRoomMember().lock();
        auto room = Network::GetRoom().lock();
        if (!member || !room) {
            done(PPNetStatusNetworkError);
            return;
        }
        if (member->GetState() == RoomMember::State::Joining || member->IsConnected() ||
            room->GetState() == Network::Room::State::Open) {
            done(PPNetStatusAlreadyInRoom);
            return;
        }
        if (![PPMultiplayer isValidRoomName:nameCopy]) {
            done(PPNetStatusCreateRoomError);
            return;
        }
        const std::string nickname = ConsoleNickname();
        if (![PPMultiplayer isValidNickname:PlanetPort::ToNSString(nickname)]) {
            DeliverEvent(PPNetStatusUnknownError, PlanetPort::ToNSString(nickname),
                         @"Il nome giocatore deve avere da 4 a 10 caratteri (lettere, numeri, "
                         @"spazi, . _ -). Cambialo nella sezione Multiplayer.");
            done(PPNetStatusUnknownError);
            return;
        }

        const u16 room_port = port != 0 ? port : Network::DefaultRoomPort;
        const u32 max_members =
            static_cast<u32>(std::clamp<NSUInteger>(maxPlayers, 2, 16));
        const std::string password_std = PlanetPort::ToStdString(passwordCopy);

        const bool created =
            room->Create(PlanetPort::ToStdString(nameCopy), "", "", room_port, password_std,
                         max_members, nickname, PlanetPort::ToStdString(gameCopy), preferredGameID,
                         std::make_unique<Network::VerifyUser::NullBackend>(), {});
        if (!created) {
            LOG_ERROR(Frontend, "PlanetPort: Room::Create failed on port {}", room_port);
            done(PPNetStatusCreateRoomError);
            return;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        g_last_error = -1;
        Core::System& system = Core::System::GetInstance();
        member->Join(nickname, Service::CFG::GetConsoleIdHash(system), "127.0.0.1", room_port, 0,
                     Service::CFG::GetConsoleMacAddress(system), password_std);

        const PPNetStatus status = WaitForJoin(member, std::chrono::milliseconds(3000));
        if (status != PPNetStatusNoError) {
            LeaveAndDestroy();
            done(status == PPNetStatusCouldNotConnect ? PPNetStatusCreateRoomError : status);
            return;
        }
        DeliverRoomChanged();
        done(PPNetStatusNoError);
    });
}

- (void)joinRoomAtAddress:(NSString*)address
                     port:(uint16_t)port
                 password:(NSString*)password
               completion:(void (^)(PPNetStatus))completion {
    NSString* addressCopy = [address stringByTrimmingCharactersInSet:
                                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* passwordCopy = [password copy] ?: @"";
    void (^done)(PPNetStatus) = ^(PPNetStatus status) {
        PlanetPort::RunOnMain(^{
            if (completion) {
                completion(status);
            }
        });
    };

    dispatch_async(NetworkQueue(), ^{
        if (!g_activated.load()) {
            done(PPNetStatusRoomUninitialized);
            return;
        }
        auto member = Network::GetRoomMember().lock();
        if (!member) {
            done(PPNetStatusNetworkError);
            return;
        }
        if (member->GetState() == RoomMember::State::Joining || member->IsConnected()) {
            done(PPNetStatusAlreadyInRoom);
            return;
        }
        if (addressCopy.length == 0) {
            done(PPNetStatusCouldNotConnect);
            return;
        }
        const std::string nickname = ConsoleNickname();
        if (![PPMultiplayer isValidNickname:PlanetPort::ToNSString(nickname)]) {
            DeliverEvent(PPNetStatusUnknownError, PlanetPort::ToNSString(nickname),
                         @"Il nome giocatore deve avere da 4 a 10 caratteri (lettere, numeri, "
                         @"spazi, . _ -). Cambialo nella sezione Multiplayer.");
            done(PPNetStatusUnknownError);
            return;
        }

        const u16 room_port = port != 0 ? port : Network::DefaultRoomPort;
        const std::string address_std = PlanetPort::ToStdString(addressCopy);
        g_last_error = -1;
        Core::System& system = Core::System::GetInstance();
        // Blocks up to ~5 s while ENet connects.
        member->Join(nickname, Service::CFG::GetConsoleIdHash(system), address_std.c_str(),
                     room_port, 0, Service::CFG::GetConsoleMacAddress(system),
                     PlanetPort::ToStdString(passwordCopy));

        const PPNetStatus status = WaitForJoin(member, std::chrono::milliseconds(4000));
        if (status != PPNetStatusNoError) {
            if (member->IsConnected()) {
                member->Leave();
            }
            ClearCache();
            done(status);
            return;
        }
        DeliverRoomChanged();
        done(PPNetStatusNoError);
    });
}

- (void)leaveRoomWithCompletion:(void (^)(void))completion {
    dispatch_async(NetworkQueue(), ^{
        LeaveAndDestroy();
        DeliverRoomChanged();
        PlanetPort::RunOnMain(^{
            if (completion) {
                completion();
            }
        });
    });
}

#pragma mark Chat / moderation

- (void)sendChatMessage:(NSString*)message {
    NSString* trimmed =
        [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return;
    }
    std::string text = PlanetPort::ToStdString(trimmed);
    constexpr std::size_t kMaxBytes = Network::MaxMessageSize;
    if (text.size() > kMaxBytes) {
        std::size_t cut = kMaxBytes;
        // Do not split a UTF-8 sequence: back up to a lead byte.
        while (cut > 0 && (static_cast<unsigned char>(text[cut]) & 0xC0) == 0x80) {
            --cut;
        }
        text.resize(cut);
    }

    dispatch_async(NetworkQueue(), ^{
        auto member = Network::GetRoomMember().lock();
        if (!member || !IsJoinedState(member->GetState())) {
            return;
        }
        member->SendChatMessage(text);
        // The room relays chat to everyone except the sender: echo locally.
        DeliverEvent(PPNetStatusChatMessage, PlanetPort::ToNSString(member->GetNickname()),
                     PlanetPort::ToNSString(text), YES);
    });
}

- (void)sendModeration:(Network::RoomMessageTypes)type nickname:(NSString*)nickname {
    const std::string target = PlanetPort::ToStdString(nickname);
    if (target.empty()) {
        return;
    }
    dispatch_async(NetworkQueue(), ^{
        auto member = Network::GetRoomMember().lock();
        if (!member || member->GetState() != RoomMember::State::Moderator) {
            return;
        }
        bool found = false;
        {
            std::scoped_lock lock{g_cache_mutex};
            for (PPRoomMember* entry in g_members) {
                if ([entry.nickname isEqualToString:nickname]) {
                    found = true;
                    break;
                }
            }
        }
        if (found) {
            member->SendModerationRequest(type, target);
        }
    });
}

- (void)kickMember:(NSString*)nickname {
    [self sendModeration:Network::IdModKick nickname:nickname];
}

- (void)banMember:(NSString*)nickname {
    [self sendModeration:Network::IdModBan nickname:nickname];
}

@end
