/*
 * CRManager.h — the cross-library client API of libcrane.dylib.
 *
 * IMPORTANT PROVENANCE NOTE
 * -------------------------
 * libcrane.dylib is one of the six binaries in the original package that has
 * NO IDA export directory. Its *API surface* was recovered (CONFIRMED_STATIC)
 * from `objc_msgSend` selector literals in the exported binaries and from
 * `__TEXT,__objc_methname` in libcrane itself; its *implementation* is not
 * available to this project.
 *
 * Consequences, tracked as U-01/U-04/U-06 in analysis/uncertainty_register.md:
 *   - the exact XPC interface spoken to cranehelperd is unknown, so this
 *     reconstruction defines its own and cannot talk to the original daemon;
 *   - container identifier generation and the on-disk metadata format are
 *     reconstructed from the confirmed path component and marked INFERRED;
 *   - the backup archive layout is not reproduced.
 *
 * Every declaration below is either:
 *   [API]    - a selector observed being sent to CraneManager, or present in
 *              libcrane's own __objc_methname; the signature is the minimal
 *              Objective-C one implied by the call sites.
 *   [INFER]  - the signature had to be inferred; behaviour may differ.
 */

#ifndef CR_MANAGER_H
#define CR_MANAGER_H

#import <Foundation/Foundation.h>

@class CraneManager;

#define CR_API
#define CR_INFER

/* The XPC interface of this reconstruction's own cranehelperd.
 * NOT the original's - see the provenance note above. */
@protocol CRHelperServiceProtocol <NSObject>
- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL works, NSArray<NSString *> *brokenDaemons, NSError *error))reply;
- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL loaded))reply;
- (void)verifyCraneSBLoadedAndReply:(void (^)(BOOL loaded))reply;
/* CraneSB 0x1782C/0x179C4. The original helper performs a privileged
 * injection fix-up and replies with (success, NSError). Reconstruction keeps
 * the selector ABI and carries the recovered fixed-purpose operation through
 * the authenticated helper transport. */
- (void)runInjectionFixUpIfNeededAndReply:(void (^)(BOOL success, NSError *error))reply;
/* Recovered CraneSB 0x11CA4 selector; backed by an authenticated,
 * bounded raw-XPC component-health check in this reconstruction. */
- (void)verifyCraneSupportLoadedIntoDaemon:(NSString *)daemon
                                      reply:(void (^)(BOOL loaded))reply;
- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                           reply:(void (^)(NSString *containerID, BOOL connectionWorks))reply;
- (void)reloadApplication:(NSString *)appID;
- (void)reloadDaemons:(NSArray<NSString *> *)daemons;
- (void)moveKeychainItemsFromContainerWithIdentifier:(NSString *)sourceContainer
                           toContainerWithIdentifier:(NSString *)destinationContainer
                        forApplicationWithIdentifier:(NSString *)appID
                                              reply:(void (^)(BOOL success))reply;
- (void)deleteKeychainItemsForContainerWithIdentifier:(NSString *)containerID
                             forApplicationIdentifier:(NSString *)appID;
- (void)getDisplayNameOfApplicationWithIdentifier:(NSString *)appID
                                             reply:(void (^)(NSString *displayName))reply;
- (void)getIdentifiersOfAllSupportedApplicationsAndReply:(void (^)(NSArray<NSString *> *identifiers))reply;
- (void)checkIsApplicationWithIdentifier:(NSString *)appID
                     supportedByCraneAndReply:(void (^)(BOOL supported))reply;
- (void)readDeviceVendorIdentifierFromApplicationWithIdentifier:(NSString *)appID
                                                                    reply:(void (^)(NSString *identifier))reply;
- (void)writeDeviceVendorIdentifier:(NSString *)identifier
          toApplicationWithIdentifier:(NSString *)appID;
- (void)getIdentifierOfType:(uint64_t)type
             forVendorName:(NSString *)vendorName
         andBundleIdentifier:(NSString *)bundleID
                    withReply:(void (^)(NSString *identifier))reply;
- (void)setIdentifier:(NSString *)identifier
                ofType:(uint64_t)type
        forVendorName:(NSString *)vendorName
    andBundleIdentifier:(NSString *)bundleID;
- (void)dumpKeychainItemsForContainerIdentifier:(NSString *)containerID
                      forApplicationIdentifier:(NSString *)appID
                                         reply:(void (^)(NSDictionary *items))reply;
- (void)restoreKeychainItems:(NSDictionary *)items
 toContainerIdentifier:(NSString *)containerID
   forApplicationIdentifier:(NSString *)appID;
@end

@protocol CRPreferencesServiceProtocol <NSObject>
- (void)dumpKeychainItemsFromContainerWithIdentifier:(NSString *)containerID
                            forApplicationIdentifier:(NSString *)appID
                                               reply:(void (^)(NSDictionary *items))reply;
- (void)restoreKeychainItemsToContainerWithIdentifier:(NSString *)containerID
                              forApplicationIdentifier:(NSString *)appID
                                       fromDictionary:(NSDictionary *)items;
- (void)migrateApplication:(NSString *)appID withAppSettings:(NSDictionary *)settings;
@end

@interface CraneManager : NSObject

+ (CraneManager *)sharedManager;

/* ---- preferences -------------------------------------------------------- */
- (id)preferenceValueForKey:(NSString *)key;                              /* [API] */
- (void)setPreferenceValue:(id)value forKey:(NSString *)key;              /* [API] */

/* ---- observation -------------------------------------------------------- */
- (void)addObserver:(id)observer;                                          /* [API] */
- (void)removeObserver:(id)observer;                                       /* [API] */

/* ---- registry ----------------------------------------------------------- */
- (BOOL)isApplicationSupportedByCrane:(NSString *)appID;                 /* [API] */
- (NSArray<NSString *> *)identifiersOfAllSupportedApplications;          /* [API] */
- (NSArray<NSString *> *)identfiersOfApplicationsThatHaveNonDefaultContainers; /* [API] - upstream spelling kept */
- (NSDictionary *)applicationSettingsForApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (void)setApplicationSettings:(NSDictionary *)settings
    forApplicationWithIdentifier:(NSString *)appID;                       /* [API] */
- (NSDictionary *)containerSettingsForContainerWithIdentifier:(NSString *)containerID
                                 ofApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (void)setContainerSettings:(NSDictionary *)settings
  forContainerWithIdentifier:(NSString *)containerID
   ofApplicationWithIdentifier:(NSString *)appID;                         /* [API] */

/* ---- containers --------------------------------------------------------- */
- (NSArray<NSString *> *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (NSString *)activeContainerIdentifierForApplicationWithIdentifier:(NSString *)appID;    /* [API] */
- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID;              /* [API] */
- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
                     reloadApplication:(BOOL)reload
       usingBiometricsIfNeededWithSuccessHandler:(void (^)(BOOL authenticated))handler; /* [API] */
- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
usingBiometricsIfNeededWithSuccessHandler:(void (^)(BOOL authenticated))handler; /* [API] */
- (NSString *)createNewContainerWithName:(NSString *)name
            forApplicationWithIdentifier:(NSString *)appID;              /* [API] */
- (void)createNewContainerWithName:(NSString *)name
                    andIdentifier:(NSString *)identifier
            forApplicationWithIdentifier:(NSString *)appID;              /* [API] */
- (void)deleteContentOfContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID;     /* [API] */
- (void)wipeContainerWithIdentifier:(NSString *)containerID
            forApplicationWithIdentifier:(NSString *)appID
                    shouldRepopulate:(BOOL)repopulate;                    /* [API] */
- (void)makeDefaultForContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID;     /* [API] */
- (void)moveOrCopyContainerFromPath:(NSString *)src toPath:(NSString *)dst move:(BOOL)move; /* [API] */
- (void)enumerate:(void (^)(NSInteger type, NSString *identifier, NSString *path, BOOL *stop))block
 pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
              ofApplicationWithIdentifier:(NSString *)appID;             /* [API] */
- (NSDictionary<NSString *, NSString *> *)pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
                                      ofApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (void)sizeOccupiedByContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
                               completionHandler:(void (^)(unsigned long long bytes))handler; /* [API] */
- (NSArray<NSString *> *)unknownContainersInsideApplicationWithIdentifier:(NSString *)appID
                                                       knownContainers:(NSSet<NSString *> *)known; /* [API] */

/* ---- naming ------------------------------------------------------------- */
- (NSString *)displayNameForApplicationWithIdentifier:(NSString *)appID; /* [API] */
/* Reconstructed from CraneSB 0xE730/0x1119C call sites; body inferred. */
- (NSString *)containerNameToDisplayInNotificationWithUserInfoOrContext:(NSDictionary *)info
                                         ofApplicationWithIdentifier:(NSString *)appID;
- (NSString *)displayNameForContainerWithIdentifier:(NSString *)containerID
                         ofApplicationWithIdentifier:(NSString *)appID
                              shouldUseShortVersion:(BOOL)useShort;      /* [API] */

/* ---- device identifier -------------------------------------------------- */
- (BOOL)applicationHasDeviceIdentifier:(NSString *)appID;                /* [API] */
- (NSString *)deviceIdentifierToUseForContainerWithIdentifier:(NSString *)containerID
                                    ofApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (BOOL)setDeviceIdentifier:(NSString *)identifier
   ofContainerWithIdentifier:(NSString *)containerID
    andApplicationWithIdentifier:(NSString *)appID;                      /* [API] */

/* ---- process control ---------------------------------------------------- */
- (void)reloadAccountsdDaemon;                                           /* [API] */
- (void)reloadAppstoreDaemons;                                          /* [API] */
- (void)reloadMusicDaemons;                                             /* [API] */
- (void)reloadGameDaemons;                                              /* [API] */
- (void)reloadApplicationWithIdentifier:(NSString *)appID;              /* [API] */
- (void)reloadApplicationWithIdentifier:(NSString *)appID ifContainerIsActive:(NSString *)containerID; /* [API] */
- (void)flushCFPrefsdCacheForApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                reply:(void (^)(NSString *containerID, BOOL connectionWorks))reply; /* [API] */
- (BOOL)cranehelperdConnectionWorks;                                     /* [API] */
- (void)runSafeXPCBlock:(dispatch_block_t)block; /* [recovered selector; reconstruction adapter] */
- (id)cranehelperdGlobalSyncRemoteObjectProxy;                           /* [API] */
- (id)cranehelperdGlobalAsyncRemoteObjectProxy;                          /* [API] */
- (BOOL)isDylibLoaded;                                                   /* [API] */

/* ---- Game Center -------------------------------------------------------- */
- (NSArray<NSString *> *)gameCenter_enabledApplicationIdentifiers;       /* [API] libcrane 0x9800 */
- (void)gameCenter_setActiveAccount:(NSString *)account;                 /* [API] */
- (void)gameCenter_setActiveAccount:(NSString *)account
         andDontKillApplication:(NSString *)appID;                        /* [API] */
- (NSString *)gameCenter_activeAccount;                                  /* [API] */
- (NSArray<NSDictionary *> *)gameCenter_availableAccounts;                 /* [API] CranePrefs original {identifier,name} */
- (void)gameCenter_setAvailableAccounts:(NSArray<NSDictionary *> *)accounts; /* [API] */
- (BOOL)gameCenter_isAccountAvailable:(NSString *)account;                /* [API] */
- (void)gameCenter_reloadExceptApplicationWithIdentifier:(NSString *)appID; /* [API] */

/* ---- keychain ----------------------------------------------------------- */
- (BOOL)isKeychainVersionUpToDate;                                       /* [API] */
- (void)updateKeychainVersion;                                           /* [API] */

/* ---- Crane hooks used by other components ------------------------------- */
- (void)unregisterFromNotificationsIfNeededForContainerIdentifier:(NSString *)containerID
                                ofApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (void)resetBadgeOfContainerWithIdentifier:(NSString *)containerID
                ofApplicationWithIdentifier:(NSString *)appID;           /* [API] */
- (void)switchBadgesOfContainerWithIdentifier:(NSString *)containerID
                      andContainerWithIdentifier:(NSString *)otherContainerID
                   ofApplicationWithIdentifier:(NSString *)appID;         /* [API] */

- (void)migrateApplication:(NSString *)appID withAppSettings:(NSDictionary *)settings; /* [API] */

- (void)resetLastError;                                                  /* [API] */
- (id)getLastError;                                                      /* [API] */
- (void)_setXPCUnsandboxHandler:(id)handler;                             /* [API] - CraneSupport 0x6C5C */

@end

#endif /* CR_MANAGER_H */