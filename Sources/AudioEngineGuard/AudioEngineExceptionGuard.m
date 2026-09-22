// AudioEngineExceptionGuard.m
// AudioEngineGuard
//
// Minimal skeleton stub: compiles, fail-fast prints, returns an error.
// The real ObjC @try/@catch bridge for AVFAudio ships in a later PR.

#import "include/AudioEngineExceptionGuard.h"
#import <stdio.h>

NSError * _Nullable NanoDictateRunAudioEngineBlockGuarded(void (^ _Nonnull block)(void)) {
  fputs("AudioEngineGuard: not implemented in minimal skeleton\n", stderr);
  return [NSError errorWithDomain:@"Domain.NanoDictate.AudioEngine" code:1
                         userInfo:@{NSLocalizedDescriptionKey: @"not implemented in minimal skeleton"}];
}