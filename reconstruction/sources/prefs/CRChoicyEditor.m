/*
 * Optional Choicy editor, recovered from CranePrefs 0x3F108-0x3F774.
 * The initializer's selector references at 0x58FD0-0x58FF0 resolve to
 * shouldShowAppPlugIns, shouldShowTweak:, readPreferences, writePreferences
 * and sendPostNotification. Keep Choicy's UI while replacing its store.
 */
#import "CRChoicyEditor.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"

/* Compile-time signatures only; no hard link to the optional Choicy class. */
@protocol CRChoicyEditorSurface
- (id)specifier;
- (id)propertyForKey:(NSString *)key;
- (NSString *)applicationIdentifier;
- (NSString *)containerIdentifier;
- (NSString *)dylibName;
- (NSMutableDictionary *)processPreferences;
- (void)setProcessPreferences:(NSMutableDictionary *)preferences;
- (BOOL)shouldShowAppPlugIns;
- (BOOL)shouldShowTweak:(id)tweak;
- (void)readPreferences;
- (void)writePreferences;
- (void)sendPostNotification;
@end

static Class gCRChoicyEditorClass;
static BOOL (*gCRChoicyOriginalShouldShowTweak)(id, SEL, id);

static id CRChoicyGet(id object, SEL selector)
{
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

/* 0x3F250: the container belongs to the navigation specifier. */
static id CRChoicyContainerIdentifier(id self, SEL selector)
{
    (void)selector;
    id specifier = CRChoicyGet(self, @selector(specifier));
    return ((id (*)(id, SEL, id))objc_msgSend)(
        specifier, @selector(propertyForKey:), @"containerIdentifier");
}

/* Reconstruction guard: a stale detail page must not recreate a removed
 * container or write to DEFAULT/the application's global Choicy settings. */
static BOOL CRChoicyContext(id self, NSString **appID, NSString **containerID)
{
    id app = CRChoicyGet(self, @selector(applicationIdentifier));
    id container = CRChoicyContainerIdentifier(self, @selector(containerIdentifier));
    if (![app isKindOfClass:NSString.class] || ![app length] ||
        ![container isKindOfClass:NSString.class] || ![container length] ||
        [container isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return NO;
    if (![[CraneManager.sharedManager
        containerIdentifiersOfApplicationWithIdentifier:app] containsObject:container])
        return NO;
    *appID = app;
    *containerID = container;
    return YES;
}

static BOOL CRChoicyShouldShowAppPlugIns(id self, SEL selector)
{
    (void)self;
    (void)selector;
    return NO; /* 0x3F39C: this editor configures only the application. */
}

static BOOL CRChoicyShouldShowTweak(id self, SEL selector, id tweak)
{
    SEL dylibName = @selector(dylibName);
    if (![tweak respondsToSelector:dylibName])
        return NO;
    id name = CRChoicyGet(tweak, dylibName);
    /* Leading space is part of the installed main dylib name (0x3F3A4). */
    if ([name isKindOfClass:NSString.class] && [name isEqualToString:@" Crane"])
        return NO;
    return gCRChoicyOriginalShouldShowTweak(self, selector, tweak);
}

static void CRChoicyReadPreferences(id self, SEL selector)
{
    (void)selector;
    NSString *appID = nil, *containerID = nil;
    NSDictionary *configuration = nil;
    if (CRChoicyContext(self, &appID, &containerID)) {
        id stored = [CraneManager.sharedManager
            containerSettingsForContainerWithIdentifier:containerID
                              ofApplicationWithIdentifier:appID]
            [CRCContainer_ChoicyConfigurationOverwrite];
        if ([stored isKindOfClass:NSDictionary.class])
            configuration = stored;
    }
    /* 0x3F44C: independent mutable dictionary; nil becomes empty. */
    NSMutableDictionary *preferences = [configuration mutableCopy] ?: [NSMutableDictionary new];
    ((void (*)(id, SEL, id))objc_msgSend)(
        self, @selector(setProcessPreferences:), preferences);
}

static void CRChoicyWritePreferences(id self, SEL selector)
{
    (void)selector;
    NSString *appID = nil, *containerID = nil;
    if (!CRChoicyContext(self, &appID, &containerID))
        return;
    id preferences = CRChoicyGet(self, @selector(processPreferences));
    if (![preferences isKindOfClass:NSDictionary.class] ||
        ![NSPropertyListSerialization propertyList:preferences
                                 isValidForFormat:NSPropertyListBinaryFormat_v1_0])
        return;
    CraneManager *manager = CraneManager.sharedManager;
    /* 0x3F5C0: merge only the override into the latest container settings,
     * preserving name, notification permissions and other unrelated keys. */
    NSMutableDictionary *settings = [[manager
        containerSettingsForContainerWithIdentifier:containerID
                          ofApplicationWithIdentifier:appID] mutableCopy];
    if (!settings)
        return;
    settings[CRCContainer_ChoicyConfigurationOverwrite] = [preferences copy];
    [manager setContainerSettings:settings forContainerWithIdentifier:containerID
        ofApplicationWithIdentifier:appID];
}

static void CRChoicySendPostNotification(id self, SEL selector)
{
    (void)selector;
    NSString *appID = nil, *containerID = nil;
    if (!CRChoicyContext(self, &appID, &containerID))
        return;
    CraneManager *manager = CraneManager.sharedManager;
    /* 0x3F774: editing an inactive container must not kill the active app. */
    if ([[manager activeContainerIdentifierForApplicationWithIdentifier:appID]
        isEqualToString:containerID])
        [manager reloadApplicationWithIdentifier:appID];
}

/* Only install callbacks whose ABI we can actually satisfy. Metadata comes
 * from the loaded superclass, so arm64 and arm64e BOOL encodings are retained. */
static BOOL CRChoicyMethodMatches(Class parent, SEL selector,
                                  const char *result, BOOL objectArgument)
{
    Method method = class_getInstanceMethod(parent, selector);
    if (!method)
        return NO;
    NSMethodSignature *signature = [NSMethodSignature
        signatureWithObjCTypes:method_getTypeEncoding(method)];
    const char *type = signature.methodReturnType;
    if (!signature || strlen(type) != 1 || !strchr(result, type[0]) ||
        signature.numberOfArguments != (objectArgument ? 3u : 2u))
        return NO;
    return !objectArgument ||
        [signature getArgumentTypeAtIndex:2][0] == '@';
}

Class CRChoicyContainerEditorClass(void)
{
    @synchronized(CraneManager.class) {
        if (gCRChoicyEditorClass)
            return gCRChoicyEditorClass;
        Class parent = NSClassFromString(@"CHPProcessConfigurationListController");
        if (!parent)
            return Nil;
        struct {
            const char *name;
            IMP implementation;
            const char *result;
            BOOL objectArgument;
        } overrides[] = {
            {"shouldShowAppPlugIns", (IMP)CRChoicyShouldShowAppPlugIns, "Bc", NO},
            {"shouldShowTweak:", (IMP)CRChoicyShouldShowTweak, "Bc", YES},
            {"readPreferences", (IMP)CRChoicyReadPreferences, "v", NO},
            {"writePreferences", (IMP)CRChoicyWritePreferences, "v", NO},
            {"sendPostNotification", (IMP)CRChoicySendPostNotification, "v", NO},
        };
        if (!CRChoicyMethodMatches(parent, @selector(specifier), "@", NO) ||
            !CRChoicyMethodMatches(parent, @selector(applicationIdentifier), "@", NO) ||
            !CRChoicyMethodMatches(parent, @selector(processPreferences), "@", NO) ||
            !CRChoicyMethodMatches(parent, @selector(setProcessPreferences:), "v", YES))
            return Nil;
        for (NSUInteger i = 0; i < sizeof(overrides) / sizeof(overrides[0]); i++) {
            if (!CRChoicyMethodMatches(parent, sel_registerName(overrides[i].name),
                overrides[i].result, overrides[i].objectArgument))
                return Nil;
        }

        /* Do not reuse a foreign class with this name or modify Choicy itself. */
        if (NSClassFromString(@"CRPContainerChoicyOverwriteListController"))
            return Nil;
        Class editor = objc_allocateClassPair(parent,
            "CRPContainerChoicyOverwriteListController", 0);
        if (!editor)
            return Nil;
        if (!class_addMethod(editor, @selector(containerIdentifier),
                             (IMP)CRChoicyContainerIdentifier, "@@:")) {
            objc_disposeClassPair(editor);
            return Nil;
        }
        for (NSUInteger i = 0; i < sizeof(overrides) / sizeof(overrides[0]); i++) {
            SEL methodSelector = sel_registerName(overrides[i].name);
            Method inherited = class_getInstanceMethod(parent, methodSelector);
            if (!class_addMethod(editor, methodSelector, overrides[i].implementation,
                                 method_getTypeEncoding(inherited))) {
                objc_disposeClassPair(editor);
                return Nil;
            }
        }
        gCRChoicyOriginalShouldShowTweak = (BOOL (*)(id, SEL, id))
            method_getImplementation(class_getInstanceMethod(parent,
                @selector(shouldShowTweak:)));
        objc_registerClassPair(editor);
        gCRChoicyEditorClass = editor;
        return editor;
    }
}
