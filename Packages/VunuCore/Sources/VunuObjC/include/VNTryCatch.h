#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C exception (e.g. from AVAudioEngine) into an NSError instead of crashing.
FOUNDATION_EXPORT NSError * _Nullable VNTryCatch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
