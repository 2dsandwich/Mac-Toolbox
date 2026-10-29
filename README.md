# MONEY!

A launcher for macOS that does a lot more than launch. Press ⌘Space and type: apps, answers and tools show up as you go. Everything else lives one keystroke away.

## What's in it

- **Search** — apps, System Settings pages and files, plus instant answers while you type: weather, currency, units, time zones, dates, maths, colours, passwords, QR codes, definitions, emoji and quick switches like dark mode or Night Shift.
- **Clipboard history** — text, images and files, searchable, with pins. Passwords and API keys are never saved.
- **Text from screen (⌘3)** — select any part of the screen to copy its text, or scan a QR code.
- **Dictation (⌥Space or Fn)** — hold to talk, tap for hands-free. Speak English, Japanese or any mix; it's transcribed on device, cleaned up (fillers, self-corrections, lists) for wherever you're typing, and pasted at the cursor.
- **Meetings (⌘4)** — records your mic and the Mac's sound, transcribes live, writes notes afterwards, and lets you ask questions about it. A floating window that stays out of screen shares.
- **Clock (⌘5)** — focus sessions, several timers and stopwatches at once, and alarms.
- **Dynamic notch** — what's going on (music, timers, meetings, dictation) around the notch, with a drag-to-arrange order it remembers.
- **Also** — calculator, translate, weather for any place, sticky notes, a per-app volume mixer, an All Apps grid, and your stats.

## Requirements

- macOS 27 on Apple Silicon
- Xcode command line tools (Swift 6)

## Build

```sh
./scripts/build.sh            # builds build/MONEY!.app
./scripts/build.sh --install  # copies it to /Applications and opens it
```

It signs with your Apple Development identity when you have one, so permissions survive rebuilds.

## Permissions

MONEY! asks for what each feature needs: Accessibility (to paste and to read selected text), Microphone (dictation and meetings), Screen Recording (text from screen and meeting audio), Location (local weather) and Automation (now playing in Music and Spotify).

## AI

Polishing dictation, meeting notes and translation can use Apple's on-device model, Claude, any OpenAI-compatible service or Ollama, chosen per task in Settings › AI. API keys are kept in the Keychain, never in settings files.

## Privacy

Clipboard history, meetings, notes and stats stay on your Mac (`~/Library/Application Support/MONEY`). Nothing is sent anywhere except to the AI service you pick and the public APIs behind the live answers (Open-Meteo, Frankfurter, CoinGecko, holidays-jp, ipify, and Apple's iTunes Search for song credits).
