// AudioEngineExceptionGuard.m
// AudioEngineGuard
//
// Реализация шлюза ObjC @try/@catch — см. одноимённый заголовок.

#import "AudioEngineExceptionGuard.h"

NSError *NanoDictateRunAudioEngineBlockGuarded(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        if (exception.name) {
            userInfo[@"NSExceptionName"] = exception.name;
        }
        if (exception.reason) {
            userInfo[@"NSExceptionReason"] = exception.reason;
        }
        // NSLocalizedDescriptionKey — единственный ключ, который Foundation
        // показывает в localizedDescription поверх остальных (name/reason с
        // fallback).
        NSString *localizedDescription =
            (exception.reason.length > 0) ? exception.reason
            : (exception.name.length > 0) ? exception.name
            : @"Audio engine exception";
        userInfo[NSLocalizedDescriptionKey] = localizedDescription;
        return [NSError errorWithDomain:@"Domain.NanoDictate.AudioEngine"
                                   code:1
                               userInfo:userInfo];
    }
}

void NanoDictateRaiseAudioEngineTestException(void) {
    @throw [NSException exceptionWithName:@"NanoDictateTestException"
                                   reason:@"intentional raise for unit test"
                                 userInfo:nil];
}