# Held — pitch trainer (iOS)

Sing a note, hold it, watch the trace. Same YIN detector as the desktop
`pitch-trainer.html` v1 — validate there first if you haven't; it's the
identical algorithm.

## Build

```
cd held-ios
xcodegen generate
open Held.xcodeproj
```

Set your signing team on the Held target, then run on device
(the simulator has no real mic input worth trusting — use hardware).

## Usage

1. **Start listening** → allow mic on first run.
2. Set target with −/+ (or `scope` button to snap target to whatever
   you're currently singing).
3. `speaker` button plays a 1.6s sine reference through the speaker.
4. Hold inside ±15¢ to build the hold streak. Trace shows the last 8s,
   shaded band = ±10¢.

**Detector self-test:** start listening, then play the reference with
volume up. The trace should pin the target line within a couple cents.
If it does, everything it shows about your voice is real.

## Architecture

- `YIN.swift` — pitch detection (de Cheveigné & Kawahara 2002),
  sample-rate adaptive, silence-gated, confidence-gated.
- `PitchEngine.swift` — AVAudioEngine input tap (4096 frames),
  median-of-3 smoothing in log-frequency space, hold streak,
  8s trace ring buffer, reference tone via AVAudioPlayerNode.
- `ContentView.swift` — SwiftUI. Trace drawn with Canvas inside
  TimelineView(.animation) for wall-clock scrolling.

## Known risks (untested on hardware)

- `AVAudioSession` category `.playAndRecord` + `.measurement` mode:
  if input is unexpectedly quiet, try mode `.default` — `.measurement`
  picks a different mic tuning on some devices.
- Input tap `bufferSize: 4096` is a request, not a guarantee; the
  detector handles arbitrary sizes ≥512 but precision drops below ~2048.
  Log `buffer.frameLength` if results look off.
- If the reference tone comes out of the earpiece instead of the
  speaker, the `.defaultToSpeaker` option isn't taking — force it with
  `session.overrideOutputAudioPort(.speaker)` after activation.
- iPhone mics have hardware noise suppression that `.measurement`
  mostly bypasses, but AirPods as input will fight you — use the
  built-in mic.

## Recall mode (delayed pitch recall)

Second tab. Trains pitch memory + production, not matching:

1. Random target inside your configured range (default A2–E4) —
   set LOW/HIGH to your actual comfortable range first.
2. Reference plays **once**. There is deliberately no replay button.
3. Enforced silent delay: 3s / 5s / 10s. The delay is the difficulty
   ratchet — move up only when hit rate at the current level is solid.
4. SING. The app captures the **first 500ms** of your voicing and
   scores the median — the first landing counts, no correcting after
   you hear yourself.
5. Hit = within ±25¢. Session tracks trials, hit rate, median error,
   best streak (streak persists across sessions).

Scoring is exact-octave (the reference plays inside your range, so
octave-free credit would only hide errors). Trials auto-start the mic
if it isn't running.

A well-formed weekly target looks like: "≥70% hit rate over 20 trials
at 5s delay." Fail condition included by construction.

## Range finder

"find my range" link under the Recall settings. Two guided captures:
lowest comfortable note (a note you could sing a word on — not vocal
fry), then highest without strain. A note only registers after being
held stably (±0.5 semitone) for 1.5s, which rejects fry, squeaks, and
glissando drive-bys; the progress bar shows the lock building.

The suggested training range trims 2 semitones off each end — trials
at your edges measure strain, not pitch memory. One tap applies it to
Recall. Redo it warmed up vs cold and you'll see why morning numbers
shouldn't set your range.

## Ear mode (pitch discrimination)

Third tab. No mic needed — playback only. Two tones play; answer
whether the second was HIGHER or LOWER. The gap shrinks on a ladder:
600¢ → 300¢ → 100¢ → 50¢ → 25¢ → 12¢. Four of the last five correct
promotes you a level; two consecutive misses demotes.

The threshold stat is the smallest gap you've answered at ≥75%
accuracy over ≥8 lifetime trials. The clinical line for congenital
amusia ("tone deafness") is failing at one semitone (100¢). Clearing
100¢ rules it out; most untrained listeners settle at 25–50¢. Replay
is allowed while answering — this is untimed perception, not memory.

Level, best, and per-level tallies persist across sessions.

## Intervals mode (ear TRAINING, not testing)

Fourth tab, two drills behind a segmented toggle:

**Hear** — root + second note play; name the interval from the unlocked
set. Starts with Unison / P5 / Octave (maximally distinct); 10 of the
last 12 correct unlocks the next interval in distinctiveness order,
through to the tritone. Song mnemonics behind the "hint" button
(P5 = Twinkle Twinkle, P8 = Over the Rainbow, m2 = Jaws…).

**Sing** — root plays, prompt says e.g. "Perfect 5th ↑", produce it.
Stable-hold capture (±0.5 semitone for 1s), scored against the target
with a training-grade ±50¢ hit band. Roots are sampled so the target
stays inside your saved recall range. "Play the target" after each
attempt closes the feedback loop.

Unlock progress persists. Hear/Sing accuracy are session stats.

## Songs tab (melody library)

Fifth tab. Downloads melody tracks from a public GitHub repo
(`held-tracks`) and practices them chunk by chunk.

- **Repo row**: tap the `owner/held-tracks` text to edit. **Token
  row**: paste a fine-grained PAT (Contents: read-only, single repo)
  for private repos — stored in Keychain. Fetches go through the
  GitHub contents API; offline after download.
- **Practice**: call-and-response per ~9s chunk. **Listen** plays the
  chunk as synth tones; **Sing** gives a 1.2s count-in, then scrolls
  the cursor silently while the mic scores you (the reference never
  plays while you sing — same reasoning as Recall). Per-note bars go
  green (≥60% of frames within ±50¢) or red; chunk score = notes
  passed. Best score per chunk persists.
- **Transpose** (±ST) shifts the whole track; persisted per track.
- **Loop** re-runs Sing on the same chunk after showing the score.

Publish flow from the Mac:

```
python3 extract_melody.py song.mp3
python3 publish_track.py song.notes.json --title "Song Title"
```

(`publish_track.py` lives in the held-tracks repo.)

## Secrets.swift (build-time token)

`Held/Secrets.swift` is gitignored. Fill in `githubToken` (and
`defaultRepo`) locally and every build you make — including installs
onto a second device — ships with the token baked in; no Songs-tab
entry needed. The in-app token field still overrides it if set.
Blank the file before zipping source for a handoff.
