// AudioEngineExceptionGuard.m
// AudioEngineGuard
//
// Реализация шлюза ObjC @try/@catch — см. одноимённый заголовок.

#import "AudioEngineExceptionGuard.h"

NSError *DictationRunAudioEngineBlockGuarded(void (^block)(void)) {
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
        return [NSError errorWithDomain:@"Domain.Dictation.AudioEngine"
                                   code:1
                               userInfo:userInfo];
    }
}

void DictationRaiseAudioEngineTestException(void) {
    @throw [NSException exceptionWithName:@"DictationTestException"
                                   reason:@"intentional raise for unit test"
                                 userInfo:nil];
}