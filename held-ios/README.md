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
