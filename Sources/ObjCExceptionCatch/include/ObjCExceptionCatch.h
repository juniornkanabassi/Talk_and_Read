// Swift cannot catch an Objective-C exception; AVFAudio raises them where it should return an error (Player.play).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. An Objective-C exception it raises is caught and returned as an error (domain: the exception's name,
/// description: its reason); nil when the block finished normally.
NSError *_Nullable TRCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
