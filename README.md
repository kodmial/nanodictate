# AltDictation

Dictation by double-Alt keystroke for macOS.

This project provides three components:

- **DictationCore** -- shared library with core dictation logic.
- **DictatorAgent** -- background agent that listens for the trigger.
- **dictatorctl** -- command-line control utility.

## Requirements

- macOS 12+
- Swift 5.7 (Xcode 14 Command Line Tools)

## Build

Сборка через локальный toolchain (`~/.swift-toolchain`): после сборки оба бинаря
переподписываются, а `dictatorctl` симлинком ставится в `/usr/local/bin`,
поэтому работает как обычная команда без пути.

```sh
./build.sh
```
