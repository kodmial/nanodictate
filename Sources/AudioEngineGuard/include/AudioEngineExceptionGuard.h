// AudioEngineExceptionGuard.h
// AudioEngineGuard
//
// Шлюз: выполняет блок AVFAudio-операций под ObjC @try/@catch и превращает
// NSException в NSError.
//
// Зачем: AVAudioEngine умеет поднимать NSException (например, SetOutputFormat
// внутри installTap/prepare/start при рассинхронизации аппаратного формата
// после смены устройства или выдачи TCC-гранта микрофона). В Swift NSException
// не ловится ни do/catch, ни defer — процесс падает SIGABRT (подтверждено
// crash-репортом NanoDictateAgent). Этот модуль переводит исключение в NSError,
// и ветка ошибки становится обычным throw-путём: cleanup tap/движка и
// терминальное сообщение в оверлее.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Выполняет `block` под @try/@catch. Возвращает nil, если блок прошёл без
/// исключения, иначе — NSError с именем и причиной перехваченного NSException
/// (домен "Domain.NanoDictate.AudioEngine", код 1).
FOUNDATION_EXPORT NSError * _Nullable NanoDictateRunAudioEngineBlockGuarded(void (^ _Nonnull block)(void));

/// Тестовый триггер: поднимает NSException, чтобы unit-тест проверил
/// превращение исключения в ошибку (симуляция AVFAudio-краша).
FOUNDATION_EXPORT void NanoDictateRaiseAudioEngineTestException(void);

NS_ASSUME_NONNULL_END