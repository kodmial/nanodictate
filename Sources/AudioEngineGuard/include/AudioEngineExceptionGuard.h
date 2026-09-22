// AudioEngineExceptionGuard.h
// AudioEngineGuard
//
// Minimal skeleton stub: the real ObjC NSException bridge for AVFAudio
// (NanoDictateRunAudioEngineBlockGuarded) ships in a later PR.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSError * _Nullable NanoDictateRunAudioEngineBlockGuarded(void (^ _Nonnull block)(void));

NS_ASSUME_NONNULL_END