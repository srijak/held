# CLAUDE.md — Held (iOS pitch trainer + song practice + quiz)

## What this is

Held is a native iOS singing trainer. Five tabs: Tune (match a target
note), Recall (delayed pitch memory), Ear (2AFC higher/lower ladder),
Intervals, and Songs (melody library + practice + Name That Tune quiz).
Owner: Srijak. Users: Srijak + his kids (quiz/multiplayer is for
visits). Currently at "v32" — everything below reflects that state.

Three components:

1. **held-ios** (this repo) — SwiftUI app, iOS 17+, bundle
   `com.srijak.held`. Built with **XcodeGen**: run `xcodegen generate`
   after adding/removing files (project.yml is the source of truth),
   then build to device from Xcode.
2. **held-tracks** — separate **private** GitHub repo
   (`srijak/held-tracks`, default branch **master**, not main — this
   has bitten us). Static track catalog: `index.json` + `tracks/*.json`
   + `tracks/*.m4a`. `publish_track.py` lives there.
3. **extract_melody.py** — Mac-side pipeline (lives in `~/c/held`):
   song audio → Demucs stem separation → pYIN → Viterbi note decoding →
   notes JSON + vocal/backing AAC clips.

## Data flow

```
song.mp3 (or --record via BlackHole)
  → extract_melody.py
      Demucs two-stem (needs TRUE STEREO input — mono is upconverted
        via ensure_stereo(); demucs expand()+in-place math crashes on
        mono under torch 2.x)
      pYIN (22050 Hz, hop 512, fmin C2, fmax C6, --min-confidence 0.35)
      median smooth + gap bridge
      viterbi_notes()  ← THE segmenter. Semitone states, deadband 0.25,
        switch_cost 3.0, dist_cost 0.05, min note 0.10s absorbed into
        neighbors. Greedy segmentation was replaced; do not regress.
      extend_notes_by_activity()  → vstart/vend from RMS voice activity
        (threshold 0.06, max 0.45s, tolerates 3-frame dropouts)
      coverage_report()  → prints % of audible vocal covered by notes +
        largest uncovered spans (diagnostic; user watches this)
      encode vocal clip  (mono, 64k AAC, peak-normalized 0.9)
      encode backing clip (stereo, 96k AAC, peak 0.7 so vocal wins in
        Both mode) — from demucs no_vocals stem
  → publish_track.py song.notes.json --title "X" [--artist Y]
      copies json + sibling .vocals.m4a/.backing.m4a into tracks/,
      rebuilds index.json, git commit+push
  → app Songs tab: pull-to-refresh index, download track (json + clips)
```

## Track JSON schema

```json
{
  "source": "file.wav", "title": "...", "artist": "...", "difficulty": 2,
  "hop_s": 0.0232,
  "notes": [{"start": s, "end": s, "midi": int, "midi_float": f,
             "vstart": s?, "vend": s?}],
  "frames": {"t": [...], "midi": [f|null,...], "rms": [0..1,...]}
}
```

- `start/end` = pitched core → **scoring windows + bright bar**.
- `vstart/vend` = voice-activity span (consonants, breathy tails) →
  **dim outer bar + synth phrase edges**. Optional; old tracks lack it.
- `frames.rms` optional (older tracks lack it).

`index.json`: `{version, tracks:[{id, file, title, artist, duration_s,
note_count, midi_lo, midi_hi, difficulty, audio?, backing?}]}`.

## App architecture (Held/*.swift)

- **PitchEngine** — @MainActor. Mic + YIN detection, publishes
  `detectedMidiFloat`. Music math statics (`noteName`, `midiToFreq`…)
  are `nonisolated` with the note table at file scope — required
  because nonisolated contexts (TrackModels) call them. Keep it so.
- **TrackLibrary** — @MainActor store. Fetches via **GitHub contents
  API** (`api.github.com/repos/<repo>/contents/<path>?ref=<branch>`,
  `Accept: application/vnd.github.raw+json`) — NOT raw.githubusercontent
  (no stable auth for private repos). Fine-grained PAT (Contents
  read-only, single repo) from the token field (Keychain, service
  `com.srijak.held`) or `Secrets.githubToken`. **Branch default is
  "master"** (persisted key `lib.branch`). Downloads to
  Documents/Tracks: `<id>.json`, `<id>.m4a`, `<id>.backing.m4a`.
  Clip downloads are best-effort/silent (known weak spot — an error
  surface was discussed, never built). 404 from GitHub usually means
  token problem, not missing repo.
- **Secrets.swift** — gitignored. `githubToken`, `defaultRepo`
  build-time fallbacks. Blank before zipping source for handoffs.
- **SongModel** — practice engine for one track. Key concepts:
  - **Phrases (chunks)**: breath-gap (≥0.35s) segmentation, packed to
    ~10s, max 12s, split at best internal gap. They are ENTRY POINTS,
    not walls: runs are continuous from selected phrase to end of
    audio; `loop` scopes the run to just that phrase (drill mode).
  - **Span**: `spanStart/spanEnd` set per run in `computeSpan()`. With
    real-audio sources the span extends to the audio file's end;
    phrase 0 starts at t=0 (intro plays). Synth spans stay note-bounded.
  - **Sources**: enum Source {vocal, backing, both, synth}, persisted
    `song.source`. Multi-stem playback is hostTime-locked
    (`scheduleFiles` plays all nodes `at:` one AVAudioTime).
  - **Modes**: Listen (playback only), Along (playback + mic scoring,
    headphones feature — speaker bleeds into detector; count-in gets up
    to 1s of audio run-in), Sing (silent, from memory).
  - **Latency**: `latencyOffset` (= session output+input latency,
    Along only) shifts sung sample timestamps; `displayLatency`
    (= output latency, any playback) lags the drawn cursor so visuals
    match the HEARD audio. Both matter on Bluetooth (~100-200ms).
    A manual ±ms sync trim was discussed as the next step if the
    session's latency estimate proves off — not yet built.
  - **Scoring**: per note, window [start+0.08, end], hit = within
    ±50 cents, pass = hitRatio ≥ 0.6 where expected sample cadence is
    assumed ~0.09s (UNTESTED against real device tap rate — if traces
    look right but scores read low, tune this constant). Notes score
    LIVE as the cursor passes them (`onTick`). Per-phrase bests persist
    (`song.scores.<trackID>`).
  - **Synth** (`LegatoSynth`, streamed in ~4s blocks off-main — a
    full-song monolithic render froze the UI): clean-reference tone.
    Notes hold their pitch, extend to next onset for gaps ≤ 0.4s
    (breath-aligned; consonant gaps sung through, real silences
    silent), ~30ms exponential smoother + 40ms glide look-ahead so
    transitions center where the voice's do, onset scoop -0.8 st,
    delayed vibrato (±7¢ @5.3Hz), formant-shaped 8-harmonic stack
    (730/1090/2450 Hz), amplitude follows the singer's shaped RMS
    envelope (frames.rms). Frame-following synthesis was removed
    deliberately: the vocal clip owns realism, the synth owns "the
    target." Extractor-side alignment: median k=3 and a
    refine_boundaries() pass that snaps Viterbi's systematically-late
    (~25-50ms) boundaries onto the raw pitch's midpoint crossing.
- **SongPracticeView / PianoRoll** — Canvas. Scrolling mode (Listen/
  Sing/Along): fixed now-line at 0.375 width, 4s window, notes flow
  toward it; brass line = listening, green = singing. Static full-
  phrase layout only when idle/scored (review). Bars: dim outer =
  vstart..vend, bright core = start..end, green/red after scoring.
  Controls: Listen / Along / Sing buttons, source Menu, loop toggle,
  transpose ±ST (persisted per track), speaker-bleed warning.
- **QuizModel / QuizView** — Name That Tune. Modes: Vocal (first N
  sung notes of the vocal stem, N: 5→2 by streak/2), Band (opening of
  the backing from 0:00, 6s→3s), Reverse (first 30s of backing,
  samples reversed in a PCM buffer). Multiplayer 1-4 players,
  pass-the-phone, per-player streak AND difficulty, running scores,
  roster persisted (`quiz.playerNames`), global best streak
  (`quiz.bestStreak`). Entry card in LibraryView is always visible;
  locked state until ≥2 downloaded tracks have vocal clips.

## UserDefaults keys
`lib.repo`, `lib.branch`, `lib.token` (Keychain, not defaults),
`song.source`, `song.transpose.<trackID>`, `song.scores.<trackID>`,
`song.realAudio` (obsolete), `quiz.bestStreak`, `quiz.source`,
`quiz.playerNames`.

## Conventions
- Colors: `Color.heldBg/.heldPanel/.heldLine/.heldText/.heldDim/
  .heldBrass/.heldGreen/.heldRed`. Monospaced small-caps labels,
  serif titles. Dark scheme.
- After adding Swift files: update nothing (project.yml globs Held/),
  just `xcodegen generate`.
- Swift concurrency is on enough to error on cross-isolation calls:
  new pure helpers on @MainActor types should be `nonisolated`.

## Open threads / known rough edges (priority order)
1. Coverage-report results from the user's next extraction decide the
   next pipeline fix (gate too high vs unscoreable delivery vs stem
   bleed). Pending user data.
2. Scoring cadence constant (0.09s) and the ±50¢/60% thresholds are
   uncalibrated against hardware.
3. Manual audio/visual sync trim (±ms, per headphone) if Bluetooth
   latency compensation proves inexact.
4. Clip download failures are silent (best-effort) — surface in
   `lastError`.
5. PAT expires ≤1 year from ~July 2026 → silent 401s. Calendar'd.
6. iOS 17 `onChange(of:)` single-param deprecation warnings; Timer
   @Sendable capture warnings. Cosmetic.
7. Ideas parked: duel/profiles layer for the drill tabs (quiz already
   has multiplayer), cents-offset sharp/flat diagnosis in review,
   Spotify playlist quiz (rejected for now — OAuth+Premium+SDK not
   worth it vs growing the library), quiz "band from vocal-entry
   window" variant.

## Working with Srijak
Direct, operational, no cushioning. Investigate before recommending
walk-away. His pushback is data — ask what's missing before defending.
"k" = full agreement. Flag "I've built enough"-type rationalizations.
Test on device is his job; write code accordingly (compile-safe,
clearly flagged unhardware-tested assumptions).
