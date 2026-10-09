/*
 * CRBadgeAction — reconstructed UIAction subclass from CraneSB 0x1C064.
 * The original badge-count producer is part of F-08 and is not yet ported.
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

API_AVAILABLE(ios(13.0))
@interface CRBadgeAction : UIAction
@property (nonatomic, copy) NSString *badgeText;
@property (nonatomic, copy) NSString *associatedApplicationID;
+ (instancetype)actionWithTitle:(NSString *)title
                      badgeText:(NSString *)badgeText
                          image:(UIImage *)image
                     identifier:(UIActionIdentifier)identifier
associatedApplicationIdentifier:(NSString *)applicationID
                        handler:(UIActionHandler)handler;
@end

@implementation CRBadgeAction

static char kCRBadgeTextKey;
static char kCRBadgeApplicationKey;

- (NSString *)badgeText
{
    return objc_getAssociatedObject(self, &kCRBadgeTextKey);
}

- (void)setBadgeText:(NSString *)badgeText
{
    objc_setAssociatedObject(self, &kCRBadgeTextKey,
                             [badgeText copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString *)associatedApplicationID
{
    return objc_getAssociatedObject(self, &kCRBadgeApplicationKey);
}

- (void)setAssociatedApplicationID:(NSString *)applicationID
{
    objc_setAssociatedObject(self, &kCRBadgeApplicationKey,
                             [applicationID copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (instancetype)actionWithTitle:(NSString *)title
                      badgeText:(NSString *)badgeText
                          image:(UIImage *)image
                     identifier:(UIActionIdentifier)identifier
associatedApplicationIdentifier:(NSString *)applicationID
                        handler:(UIActionHandler)handler
{
    UIAction *action = [UIAction actionWithTitle:title
                                           image:image
                                      identifier:identifier
                                         handler:handler];
    object_setClass(action, self);
    CRBadgeAction *badgeAction = (CRBadgeAction *)action;
    badgeAction.badgeText = badgeText;
    badgeAction.associatedApplicationID = applicationID;
    return badgeAction;
}

@end
