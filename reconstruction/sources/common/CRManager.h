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
- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL works, NSString *brokenDaemons, NSError *error, BOOL connectionWorks))reply;
- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL loaded))reply;
- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid reply:(void (^)(NSString *containerID))reply;
- (void)reloadApplicationWithIdentifier:(NSString *)appID;
- (void)reloadDaemons:(NSArray<NSString *> *)daemons;
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
- (void)getPreferenceValueForKey:(NSString *)key withReply:(void (^)(id value))reply;
- (void)setPreferenceValue:(id)value forKey:(NSString *)key;
@end

@interface CraneManager : NSObject

+ (CraneManager *)sharedManager;

/* ---- preferences -------------------------------------------------------- */
- (id)preferenceValueForKey:(NSString *)key;                              /* [API] */
- (void)setPreferenceValue:(id)value forKey:(NSString *)key;              /* [API] */

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
       usingBiometricsIfNeededWithSuccessHandler:(dispatch_block_t)handler; /* [API] */
- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
usingBiometricsIfNeededWithSuccessHandler:(dispatch_block_t)handler;      /* [API] */
- (void)createNewContainerWithName:(NSString *)name
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
- (NSArray<NSString *> *)pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
                                      ofApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (void)sizeOccupiedByContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
                               completionHandler:(void (^)(unsigned long long bytes))handler; /* [API] */
- (NSArray<NSString *> *)unknownContainersInsideApplicationWithIdentifier:(NSString *)appID
                                                       knownContainers:(NSSet<NSString *> *)known; /* [API] */

/* ---- naming ------------------------------------------------------------- */
- (NSString *)displayNameForApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (NSString *)displayNameForContainerWithIdentifier:(NSString *)containerID
                         ofApplicationWithIdentifier:(NSString *)appID
                              shouldUseShortVersion:(BOOL)useShort;      /* [API] */

/* ---- device identifier -------------------------------------------------- */
- (BOOL)applicationHasDeviceIdentifier:(NSString *)appID;                /* [API] */
- (NSString *)deviceIdentifierToUseForContainerWithIdentifier:(NSString *)containerID
                                    ofApplicationWithIdentifier:(NSString *)appID; /* [API] */
- (void)setDeviceIdentifier:(NSString *)identifier
   ofContainerWithIdentifier:(NSString *)containerID
    andApplicationWithIdentifier:(NSString *)appID;                      /* [API] */

/* ---- process control ---------------------------------------------------- */
- (void)reloadApplicationWithIdentifier:(NSString *)appID;              /* [API] */
- (void)reloadApplicationWithIdentifier:(NSString *)appID ifContainerIsActive:(BOOL)check; /* [API] */
- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                reply:(void (^)(NSString *containerID))reply; /* [API] */
- (BOOL)cranehelperdConnectionWorks;                                     /* [API] */
- (id)cranehelperdGlobalSyncRemoteObjectProxy;                           /* [API] */
- (id)cranehelperdGlobalAsyncRemoteObjectProxy;                          /* [API] */
- (BOOL)isDylibLoaded;                                                   /* [API] */

/* ---- Game Center -------------------------------------------------------- */
- (void)gameCenter_setActiveAccount:(NSString *)account;                 /* [API] */
- (void)gameCenter_setActiveAccount:(NSString *)account
         andDontKillApplication:(NSString *)appID;                        /* [API] */
- (NSString *)gameCenter_activeAccount;                                  /* [API] */
- (NSArray<NSString *> *)gameCenter_availableAccounts;                   /* [API] */
- (void)gameCenter_setAvailableAccounts:(NSArray<NSString *> *)accounts;  /* [API] */
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