/*
 * G-11 N7 — typed, stability-checked Crane source-root inventory.
 * Uses the ORIGINAL CraneManager enumerate callback to distinguish app
 * data, App Groups and PlugInKit. No child files or contents are opened.
 */
#import "CRBackupNativeSourcePreflight.h"
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@protocol CRBackupTypedSourceResolver <CRBackupSourceResolver>
- (void)enumerate:(void (^)(NSInteger type, NSString *identifier,
                            NSString *path, BOOL *stop))block
 pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
              ofApplicationWithIdentifier:(NSString *)applicationID;
@end

@interface CRBackupNativeTypedPreflight : NSObject
+ (nullable NSDictionary<NSString *, id> *)inspectApplicationIdentifier:(NSString *)applicationID
                                                     containerIdentifier:(NSString *)containerID
                                                                resolver:(id<CRBackupTypedSourceResolver>)resolver
                                                                   error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
