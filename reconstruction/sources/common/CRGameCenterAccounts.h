#ifndef CR_GAME_CENTER_ACCOUNTS_H
#define CR_GAME_CENTER_ACCOUNTS_H

#import <Foundation/Foundation.h>

/* CranePrefs original 0x15448 stores accounts as dictionaries with two
 * string fields: { identifier, name }. 0x1312C / 0x13310 enumerate those
 * dictionary fields for display and selection (DEFAULT is UI-only).
 *
 * Never rewrite existing preference data during a read. For writes, callers
 * must reject malformed arrays instead of accidentally deleting accounts
 * while normalizing old or corrupted preferences.
 */
static inline NSArray<NSDictionary *> *CRGameCenterValidatedAccounts(id value)
{
    if (![value isKindOfClass:NSArray.class])
        return @[];

    NSMutableArray<NSDictionary *> *validated = [NSMutableArray new];
    NSMutableSet<NSString *> *identifiers = [NSMutableSet new];
    for (id entry in (NSArray *)value) {
        if (![entry isKindOfClass:NSDictionary.class])
            continue;
        id identifier = entry[@"identifier"];
        id name = entry[@"name"];
        if (![identifier isKindOfClass:NSString.class] ||
            ![name isKindOfClass:NSString.class] ||
            ![identifier length] ||
            [identifier isEqualToString:@"DEFAULT"] ||
            [identifiers containsObject:identifier])
            continue;
        [identifiers addObject:identifier];
        [validated addObject:[entry copy]];
    }
    return [validated copy];
}

static inline BOOL CRGameCenterAccountsAreValidForWrite(id value)
{
    if (![value isKindOfClass:NSArray.class])
        return NO;
    /* A missing/duplicate/malformed entry is a failed write, not a request
     * to silently remove it from an account list. */
    return CRGameCenterValidatedAccounts(value).count == [(NSArray *)value count];
}

static inline BOOL CRGameCenterAccountIdentifierExists(NSArray<NSDictionary *> *accounts,
                                                        NSString *identifier)
{
    if (![identifier isKindOfClass:NSString.class] || !identifier.length)
        return NO;
    if ([identifier isEqualToString:@"DEFAULT"])
        return YES;
    for (NSDictionary *account in CRGameCenterValidatedAccounts(accounts)) {
        if ([account[@"identifier"] isEqualToString:identifier])
            return YES;
    }
    return NO;
}

/* Original libcrane 0x9AE4 returns DEFAULT for missing or unregistered
 * active account IDs; the preferences getter must not expose a stale ID to
 * gamed/accountsd after the account list changes. */
static inline NSString *CRGameCenterResolvedActiveAccount(NSArray<NSDictionary *> *accounts,
                                                           id stored)
{
    return CRGameCenterAccountIdentifierExists(accounts, stored)
        ? (NSString *)stored : @"DEFAULT";
}

/* Read-only removal preflight: a registered Game Center account must not be
 * removed while an app container still references it. Malformed settings are
 * unknown, never interpreted as "unreferenced". */
static inline BOOL CRGameCenterAccountReferencedInSettings(id appSettings,
                                                            NSString *identifier,
                                                            BOOL *valid)
{
    if (valid)
        *valid = NO;
    if (![identifier isKindOfClass:NSString.class] ||
        ![appSettings isKindOfClass:NSDictionary.class])
        return NO;
    id containers = appSettings[@"Containers"];
    if (![containers isKindOfClass:NSArray.class])
        return NO;
    for (id item in (NSArray *)containers) {
        if (![item isKindOfClass:NSDictionary.class])
            return NO;
        id account = item[@"associatedGameCenterAccount"];
        if (account && ![account isKindOfClass:NSString.class])
            return NO;
        if ([account isEqualToString:identifier]) {
            if (valid)
                *valid = YES;
            return YES;
        }
    }
    if (valid)
        *valid = YES;
    return NO;
}

#endif /* CR_GAME_CENTER_ACCOUNTS_H */
