# Prompter Video Maker

Native macOS app that turns scripts, audio recordings, or time-coded SRT files
into smooth-scrolling teleprompter videos (1920×1080 MP4) with exact timings.

**[⬇ Download the latest release](https://github.com/virtualmagician/PrompterVideoMaker/releases/latest)** —
signed & notarized, universal binary, macOS 15+. Unzip and double-click.

![Prompter Video Maker](docs/screenshot.png)

## Getting a script in

- **New Script (⌘N)** — paste or write your text. Split it into cues by
  sentences, lines, or paragraphs; line breaks and blank lines from the pasted
  text are preserved (blank lines become adjustable spacer lines). Draft
  timings are estimated from a natural reading pace so preview and export work
  immediately.
- **Record Timing** — read your script aloud right in the main window. The app
  records you, recognizes the take **on this Mac** (no cloud), and aligns the
  recognized words against your known script text, so stumbles or recognition
  errors never change a word — only the timings (and the audio) come from your
  delivery. The recording is attached to the project and can be exported with
  the video. Alternatively choose **Use Audio File…** in the same pane to take
  timings from an existing recording while keeping your written script intact.
- **Open an SRT file** — time-coded cues imported as-is ("Speaker 1:" prefixes
  stripped automatically).
- **Open an audio file** — transcribed on-device into a fully timed script
  (word-level timestamps).

## The prompter

- Real teleprompter scrolling: continuous and smooth, each cue's first line
  crosses the read marker exactly at its timestamp, upcoming lines always
  visible. Evenly spaced lines (~7 visible by default at 96 px Helvetica Neue).
- **Alternating text colors** on auto-chunked short sections (white/green by
  default) so you never lose your place.
- **Emphasis markup**, rendered live and in the export:
  - `**bold**` for vocal stress
  - `__underline__` for careful enunciation
  - `==accent==` for the accent color (default yellow, changeable) that
    overrides the alternating colors
- **AI emphasis suggestions**: with [Ollama](https://ollama.com) running
  locally, the Emphasis section suggests bold/underline/accent markers via a
  local model (e.g. Gemma). A validator guarantees the AI can only add
  markers — your words are never changed. One click clears all emphasis.
- Read-marker arrow (color/position adjustable), mirror mode for beam-splitter
  glass, background color, font/size/line-height/margins/alignment, empty-line
  height.

## Editing & export

- Edit cue text inline; nudge start/end times; split, merge, delete; insert
  empty spacer lines; shift all timings with a visible global offset.
- Live WYSIWYG preview (locked 16:9) with play/scrub and synced audio.
- Export H.264 MP4, 1920×1080 at 30/60 fps, exact timings, optionally muxing
  the project audio. Lead-in/lead-out adjustable.
- Save/load projects (`.prompterproj`), and save any style setup as your
  default for new documents.

## Headless CLI (scripting)

```bash
APP=dist/PrompterVideoMaker.app/Contents/MacOS/PrompterVideoMaker
"$APP" --export --srt script.srt --audio voice.wav --out prompter.mp4 --fps 60
"$APP" --transcribe --audio voice.wav --out script.srt
"$APP" --align --script pasted.txt --audio take.wav --out timed.srt
"$APP" --emphasize --srt script.srt --out emphasized.srt --model gemma4:latest
"$APP" --render-frame --srt script.srt --time 6.5 --out frame.png
```

## Build from source

Requires macOS 15+ and Xcode Command Line Tools.

```bash
Scripts/build_app.sh        # → dist/PrompterVideoMaker.app (signed)
Scripts/notarize.sh         # → notarized + stapled distributable zip
```
