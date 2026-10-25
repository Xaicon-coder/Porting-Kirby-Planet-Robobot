// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Multiplayer rooms (emulated 3DS local wireless relayed over UDP/ENet by Azahar's network
// library). A phone can host a room in-process or join one by address.
// Ported from Azahar's Android frontend (src/android/app/src/main/jni/multiplayer.cpp).

#import <Foundation/Foundation.h>
#import <PlanetCore/PPTypes.h>

NS_ASSUME_NONNULL_BEGIN

/// Raw values match the Android frontend's NetPlayStatus.
typedef NS_ENUM(NSInteger, PPNetStatus) {
    PPNetStatusNoError NS_SWIFT_NAME(noError) = 0,
    PPNetStatusNetworkError NS_SWIFT_NAME(networkError) = 1,
    PPNetStatusLostConnection NS_SWIFT_NAME(lostConnection) = 2,
    PPNetStatusNameCollision NS_SWIFT_NAME(nameCollision) = 3,
    PPNetStatusMacCollision NS_SWIFT_NAME(macCollision) = 4,
    PPNetStatusConsoleIdCollision NS_SWIFT_NAME(consoleIdCollision) = 5,
    PPNetStatusWrongVersion NS_SWIFT_NAME(wrongVersion) = 6,
    PPNetStatusWrongPassword NS_SWIFT_NAME(wrongPassword) = 7,
    PPNetStatusCouldNotConnect NS_SWIFT_NAME(couldNotConnect) = 8,
    PPNetStatusRoomIsFull NS_SWIFT_NAME(roomIsFull) = 9,
    PPNetStatusHostBanned NS_SWIFT_NAME(hostBanned) = 10,
    PPNetStatusPermissionDenied NS_SWIFT_NAME(permissionDenied) = 11,
    PPNetStatusNoSuchUser NS_SWIFT_NAME(noSuchUser) = 12,
    PPNetStatusAlreadyInRoom NS_SWIFT_NAME(alreadyInRoom) = 13,
    PPNetStatusCreateRoomError NS_SWIFT_NAME(createRoomError) = 14,
    PPNetStatusHostKicked NS_SWIFT_NAME(hostKicked) = 15,
    PPNetStatusUnknownError NS_SWIFT_NAME(unknownError) = 16,
    PPNetStatusRoomUninitialized NS_SWIFT_NAME(roomUninitialized) = 17,
    PPNetStatusRoomIdle NS_SWIFT_NAME(roomIdle) = 18,
    PPNetStatusRoomJoining NS_SWIFT_NAME(roomJoining) = 19,
    PPNetStatusRoomJoined NS_SWIFT_NAME(roomJoined) = 20,
    PPNetStatusRoomModerator NS_SWIFT_NAME(roomModerator) = 21,
    PPNetStatusMemberJoin NS_SWIFT_NAME(memberJoin) = 22,
    PPNetStatusMemberLeave NS_SWIFT_NAME(memberLeave) = 23,
    PPNetStatusMemberKicked NS_SWIFT_NAME(memberKicked) = 24,
    PPNetStatusMemberBanned NS_SWIFT_NAME(memberBanned) = 25,
    PPNetStatusAddressUnbanned NS_SWIFT_NAME(addressUnbanned) = 26,
    PPNetStatusChatMessage NS_SWIFT_NAME(chatMessage) = 27,
};

/// Default Azahar room port (Network::DefaultRoomPort).
FOUNDATION_EXPORT const uint16_t PPDefaultRoomPort;

@interface PPNetEvent : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) PPNetStatus status;
/// Nickname involved (member join/leave/kick/ban, chat author). Nil when not applicable.
@property (nonatomic, readonly, copy, nullable) NSString *nickname;
/// Chat text for PPNetStatusChatMessage, unbanned address for AddressUnbanned, else nil.
@property (nonatomic, readonly, copy, nullable) NSString *message;
/// YES for the local echo of a chat message sent by this device (the room does not echo).
@property (nonatomic, readonly) BOOL isLocalEcho;
@end

@interface PPRoomMember : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *nickname;
@property (nonatomic, readonly, copy) NSString *username;
/// Game currently running on that member (empty when none).
@property (nonatomic, readonly, copy) NSString *gameName;
@property (nonatomic, readonly) uint64_t gameID;
/// "AA:BB:CC:DD:EE:FF".
@property (nonatomic, readonly, copy) NSString *macAddress;
@end

@interface PPRoomInfo : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *roomDescription;
@property (nonatomic, readonly) NSUInteger memberSlots;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly, copy) NSString *preferredGame;
@property (nonatomic, readonly, copy) NSString *hostUsername;
@end

@class PPMultiplayer;

/// Every delegate method is invoked on the main queue.
@protocol PPMultiplayerDelegate <NSObject>
- (void)multiplayer:(PPMultiplayer *)multiplayer
    didReceiveEvent:(PPNetEvent *)event NS_SWIFT_NAME(multiplayer(_:didReceive:));
@optional
/// Room information or member list changed (re-read roomInfo / members).
- (void)multiplayerRoomDidChange:(PPMultiplayer *)multiplayer
    NS_SWIFT_NAME(multiplayerRoomDidChange(_:));
@end

@interface PPMultiplayer : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (class, nonatomic, readonly) PPMultiplayer *sharedMultiplayer NS_SWIFT_NAME(shared);

@property (nonatomic, weak, nullable) id<PPMultiplayerDelegate> delegate;

/// Binds the RoomMember callbacks. Requires -[PPEmulator prepareWithUserDirectory:error:]
/// (which already called Network::Init()). Idempotent. Returns NO when the network library
/// is not initialised.
- (BOOL)activate;

/// Thread-safe snapshots.
@property (atomic, readonly, getter=isJoined) BOOL joined;       // Joined or Moderator
@property (atomic, readonly, getter=isHosting) BOOL hosting;     // local Room is Open
@property (atomic, readonly, getter=isModerator) BOOL moderator;
@property (atomic, readonly, nullable) PPRoomInfo *roomInfo;     // nil when not joined
@property (atomic, readonly, copy) NSArray<PPRoomMember *> *members;

/// ^[ a-zA-Z0-9._-]{4,10}$ (room rule 4...20 chars, CFG user name limit 10).
+ (BOOL)isValidNickname:(NSString *)nickname NS_SWIFT_NAME(isValidNickname(_:));
/// ^[ a-zA-Z0-9._-]{4,20}$ (Qt frontend rule).
+ (BOOL)isValidRoomName:(NSString *)name NS_SWIFT_NAME(isValidRoomName(_:));
/// Localised (Italian) description of a status, suitable for alerts and chat system lines.
+ (NSString *)descriptionForStatus:(PPNetStatus)status NS_SWIFT_NAME(description(for:));

/// Hosts a room in-process (binds all interfaces on `port`, NullBackend verification, no public
/// announce) and joins it as moderator via 127.0.0.1. The nickname is the console user name
/// (-[PPEmulator consoleUsername]). `maxPlayers` is clamped to 2...16. Runs on a background
/// queue; completion on the main queue with NoError on success.
- (void)hostRoomNamed:(NSString *)name
                 port:(uint16_t)port
             password:(nullable NSString *)password
           maxPlayers:(NSUInteger)maxPlayers
    preferredGameName:(NSString *)preferredGameName
      preferredGameID:(uint64_t)preferredGameID
           completion:(void (^)(PPNetStatus status))completion
    NS_SWIFT_NAME(hostRoomNamed(_:port:password:maxPlayers:preferredGameName:preferredGameID:completion:));

/// Joins a room at `address` (IPv4/IPv6/host name). Background queue; completion on main with
/// NoError when Joined/Moderator, otherwise the precise error reported by the core.
- (void)joinRoomAtAddress:(NSString *)address
                     port:(uint16_t)port
                 password:(nullable NSString *)password
               completion:(void (^)(PPNetStatus status))completion
    NS_SWIFT_NAME(joinRoom(atAddress:port:password:completion:));

/// Leaves the room (and destroys it when hosting). Background queue; completion on main.
- (void)leaveRoomWithCompletion:(nullable void (^)(void))completion
    NS_SWIFT_NAME(leaveRoom(completion:));

/// Sends a chat message (trimmed, max 500 bytes) and emits a local echo event.
- (void)sendChatMessage:(NSString *)message NS_SWIFT_NAME(sendChatMessage(_:));
/// Moderation (only effective when moderator).
- (void)kickMember:(NSString *)nickname NS_SWIFT_NAME(kickMember(_:));
- (void)banMember:(NSString *)nickname NS_SWIFT_NAME(banMember(_:));

@end

NS_ASSUME_NONNULL_END
