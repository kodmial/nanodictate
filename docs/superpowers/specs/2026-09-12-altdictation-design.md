# Дизайн: AltDictation — macOS-диктовка по двойному Alt

Дата: 2026-09-12

## Задача

Легковесное нативное macOS-приложение (Swift, SwiftPM, без Xcode), которое:

1. Запускается при старте системы (LaunchAgent).
2. По **двойному нажатию Alt** показывает рядом с кареткой активного
   текстового поля анимированное окно с микрофоном (амплитуда = уровень звука).
3. Записывает звук с микрофона, по **повторному двойному Alt** отправляет
   всё аудио **одним запросом** в Speech-to-Text API (OpenAI-совместимый
   `/v1/audio/transcriptions`, модель `gigaam-v3`, провайдер — OpenAI-совместимый gateway).
4. Результат вставляет в поле, где была вызвана диктовка.
5. Enter/Esc — отмена диктовки без отправки.
6. Конфигурация подключения к API — в конфигурационном файле.
7. CLI-команда для управления (start/stop/status/config/transcribe/logs).
8. Короткий стильный звук начала и окончания записи.

## Ограничения окружения

- macOS 12.7.6 (Monterey), Intel (x86_64), Swift 5.7.2 из Command Line Tools.
- Полного Xcode нет → сборка только через **SwiftPM** (`swift build`),
  приложение не упаковывается в .app-бандл; агент — обычный исполняемый
  файл, запускаемый LaunchAgent'ом.
- API транскрипции: `https://your-gateway/audio/transcriptions`.
  - Метод: POST multipart/form-data, поля `file` (WAV/16кГц/моно) и `model` (=`gigaam-v3`).
  - Заголовок `Authorization: Bearer <ключ>` (ключ из локального файла секретов, читается в конфиге).
  - **m4a НЕ принимается** (`FILE_TYPE_NOT_ALLOWED`) → обязательно WAV.
  - Ответ: `{"text": "...", ...}`.

## Архитектура (модули)

SwiftPM-мультитаргет: библиотека `DictationCore` + 2 исполняемых таргета
(`DictatorAgent` — фоновый агент, `dictatorctl` — CLI).

### 1. HotkeyService
- `CGEventTap` на `keyDown`; фильтр по клавишам Alt (kVK_Option/RightOption).
- Детект **двойного нажатия** Alt: два keyDown с интервалом ≤ `hotkey.interval`
  (по умолчанию 0.4 с).
- Флаги: при старте диктовки перехватывать Alt-события (если нужно —
  изолированный tap, слушание без перехвата).
- Генерация событий: `onDoubleAlt` (старт), `onDoubleAlt` (повторный — finish
  и отправка), `onEnter/Esc` (отмена).

### 2. OverlayController
- Единственное `NSPanel`: уровень `.statusBar`, без активации
  (`canBecomeKey = false`), без тени-окна (реально тень есть, это ок).
- Позиция: по каретке активного поля, полученной через AX API
  (`AXUIElementCopyAttributeValue` — `kAXFocusedUIElementAttribute` →
  `kAXPositionAttribute`/`kAXSizeAttribute`). Fallback: курсор мыши.
- Содержимое: `NSHostingView` со SwiftUI-вью:
  - SV-микрофон (SF Symbols `mic.fill`), радиус пульсации = f(RMS).
  - Подпись-статус: «Слушаю…», «Отправляю…», «Ошибка сети», «Отменено».
- Показ/скрытие по событию диктовки.

### 3. AudioService
- `AVAudioEngine` (input node), формат 16 кГц моно (ресамплинг из
  аппаратного формата).
- `installTap` → накопление `AVAudioPCMBuffer` в память (непрерывно, без нарезки).
- RMS-уровень каждого буфера → `AudioLevelProvider` (для анимации).
- Методы: `start()`, `stop()` (возвращает собранные сэмплы).

### 4. WAVEncoder
- Сериализация PCM-сэмплов (Int16) в WAV (RIFF-заголовок, PCM, mono, 16 кГц,
  16 бит) в `Data` — полностью в памяти.

### 5. Transcriber
- POST multipart на endpoint из конфига (модель, ключ, base URL).
- Честный HTTP (URLSession), таймаут из конфига (по умолчанию 120 с).
- Возврат `Result<String, TranscribeError>` из `{"text": ...}`.
- Обработка HTTP != 200: читаемое сообщение.
- один ретрай при сетевом таймауте.

### 6. Inserter
- Вставка текста в активное поле через **CGEvent unicode keyDown**
  (`keyboardSetUnicodeString`), посимвольно/пачками — работает без AX-прав
  на вставку в чужие приложения.
- Символы с учётом dead-keys не нужны — идёт чистый Unicode-ввод.
- Финализация: первая буква — заглавная (как у системной диктовки), точка
  — если не хватает в конце.

### 7. SysSounds
- `AudioServicesPlaySystemSound` двумя короткими системными звуками
  (start/finish), настраиваемо.

### 8. Config
- `~/.config/dictation/config.toml` (или рядом с бинарём).
- Поля: `[api] base_url, model, api_key, api_key_file` (альтернатива пути к
  файлу с ключом), `timeout_seconds`; `[hotkey] interval_seconds, modifier`; 
  `[audio] silence...` — не нужны (нет чанков); `[sounds] enabled, start/end`;
  `[behavior] insert_mode`.
- Чтение через простой TOML-парсер (без внешних зависимостей) или JSON — 
  решается на этапе имплементации (TOML предпочтительно, провайдер lock-free).

### 9. AgentCLI (dictatorctl)
- `start` — зарегистрировать+запустить LaunchAgent
- `stop`, `status`, `config` (показать/редактировать), `logs` (хвост лога),
- `transcribe FILE` — разовая расшифровка файла (WAV/любой → конвертация
  afconvert в WAV) для проверки API, вывод текста в stdout, опция `--json` —
  сохранить сырой ответ.

### 10. LaunchAgent
- plist в `~/Library/LaunchAgents/com.dictation.agent.plist`
  (Write via `launchctl bootstrap`), `RunAtLoad = true`, `KeepAlive`.
- Логи в `~/Library/Logs/Dictation/agent.log` (и stderr/stdout туда).

## Поток данных

```
Alt-Alt ─▶ Overlay.show() + SysSounds.start + AudioService.start()
(запись, RMS → анимация)
Alt-Alt ─▶ AudioService.stop() → WAVEncoder → Transcriber.post()
   ├─ успех ─▶ Inserter.insert(text) + Overlay.show("готово") → скрыть через 0.8с
   ├─ ошибка ▶ Overlay.show("Ошибка сети, повтор…") [ретрай] → вставить частично? нет,
   │          показать ошибку, вставить то, что успело прийти (нет — текст не пришёл)
   └─ отмена (Enter/Esc) ─▶ AudioService.stop(abandon) + Overlay.hide()
```

## Ошибки и надежность

- Нет прав на микрофон: показать в окне «Нет доступа к микрофону (Системные
  настройки → Конфиденциальность → Микрофон)».
- AX: нет прав на контроль → окно у курсора мыши (fallback), вставка всё равно
  работает (CGEvent).
- Сеть: 1 ретрай, затем окно «Не удалось распознать: <причина>»; запись
  отбрасывается.
- Логи: файл в `~/Library/Logs/Dictation/`.

## Тестирование

Юнит (Swift Testing / XCTest — на 5.7 XCTest доступен):
- WAVEncoder: заголовок и сэмплы корректны (известный пейлоад).
- HotkeyService: детект двойного/одиночного Alt (мок событий).
- Transcriber: мок URLSession — парсинг ответа, ошибки HTTP.
- Config: парсинг TOML/JSON, defaults.

Интеграция (ручная):
- `dictatorctl transcribe example/Новая запись 2.m4a` — сверка с фактическим
  распознаванием (уже известен эталонный текст).
- Показ окна + запись + вставка в TextEdit/браузер.

## Вне области (v1)

- Streaming/чанки по паузам — исключено по решению пользователя.
- Значок в меню-баре/статусе — только фоновый процесс без иконки (v1).
- Несколько API-провайдеров — один (настраиваемый) OpenAI-совместимый.