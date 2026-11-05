# MONEY!

A launcher for macOS that does a lot more than launch. Press ⌘Space and type: apps, answers and tools show up as you go. Everything else lives one keystroke away.

## What's in it

- **Search**: apps, System Settings pages and files, plus instant answers while you type: weather, currency, units, time zones, dates, maths, colours, passwords, QR codes, definitions, emoji and quick switches like dark mode or Night Shift.
- **Clipboard history**: text, images and files, searchable, with pins. Passwords and API keys are never saved.
- **Text from screen (⌘3)**: select any part of the screen to copy its text, or scan a QR code.
- **Dictation (⌥Space or Fn)**: hold to talk, tap for hands-free. Speak English, Japanese or any mix; it's transcribed on device, cleaned up (fillers, self-corrections, lists) for wherever you're typing, and pasted at the cursor.
- **Dictation history ("dictation" + Tab)**: every dictation with its polished and original words, to paste, copy or polish again, plus your words this week, speed and streak. ⌃⌘V pastes the last dictation, ⌃⌘Z swaps the polished words for what you said (and back). Words you fix by hand right after a dictation join your dictionary. Drop an audio or video file in to transcribe it and save it as text or subtitles (.srt). Tone per kind of writing, your own instructions per app, and a whisper mode for a quiet voice are in Settings › Dictation.
- **Meetings (⌘4)**: records your mic (Me) and the Mac's sound (Others) with no bot, transcribes live in English and Japanese, and gives you a notepad for your own notes. When it ends, AI notes build on what you typed (your words stay bright, the rest is dimmer), shaped by a template picked from the meeting's title (1:1, standup, customer call, interview, your own). Prompts for a follow-up email, action items and decisions, chat about one meeting or all of them, copy as rich text, share the Markdown file. Today's calendar events can be recorded from the list or the notch, named after the event with its attendees. A floating window that stays out of screen shares.
- **Clock (⌘5)**: focus sessions, several timers and stopwatches at once, and alarms.
- **Ask (Tab in the empty bar)**: a quick AI answer, with web sources and follow-ups. It only opens on Tab with nothing typed.
- **Dynamic notch**: what's going on (music with synced lyrics on demand, timers, meetings, dictation, your next calendar event) around the notch, with a drag-to-arrange order it remembers. When it's open, everything else sits as tiles beside the first thing, with the battery and a camera mirror beside the notch. Swipe down to open, sideways to skip songs.
- **Windows**: halves, quarters, thirds, maximize, centre and next display on ⌃⌥ + arrows (editable), or by typing "left half". "quit other apps" and "hide other apps" too.
- **Google Calendar and Tasks**: a month/week/day calendar ("cal" + Tab) and the notch read every Google calendar you show, with colours, people, places and Meet links (Apple's Calendar when you're signed out). "tasks" + Tab opens Google Tasks: all your lists with subtasks and the recently completed ones; type to add ("call Ben tomorrow 3pm // bring the contract in Work"), ↑↓ to pick, ↩ to tick, ⌘E to edit, ⌘⌫ to delete.
- **Also**: calculator, translate, weather for any place, sticky notes, a per-app volume mixer (up to 200%), an All Apps grid, and your stats.

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

MONEY! asks for what each feature needs: Accessibility (to paste and to read selected text), Microphone (dictation and meetings), Screen Recording (text from screen and meeting audio), Location (local weather), Calendars (upcoming events) and Automation (now playing in Music and Spotify).

## AI

Polishing dictation, meeting notes and translation can use Apple's on-device model, Claude, any OpenAI-compatible service or Ollama, chosen per task in Settings › AI. API keys are kept in the Keychain, never in settings files.

## Google

Calendar and Tasks use your own OAuth client: in Google Cloud, enable the Calendar and Tasks APIs and make an OAuth client of type Desktop app. Paste its ID and secret in Settings › Google (they're filled in from Moneybag when it has them) and sign in; the browser opens, and MONEY! takes the answer on 127.0.0.1. The client and tokens stay in the Keychain. Events and tasks are cached in `~/Library/Application Support/MONEY` so the notch and the views start offline.

## Privacy

Clipboard history, dictations, meetings, notes and stats stay on your Mac (`~/Library/Application Support/MONEY`). Nothing is sent anywhere except to the AI service you pick, Google when you sign in, and the public APIs behind the live answers (Open-Meteo, Frankfurter, CoinGecko, holidays-jp, ipify, Apple's iTunes Search for song credits, and LRCLIB for lyrics of the song playing, only while lyrics are on).
