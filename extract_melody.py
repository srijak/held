#!/usr/bin/env python3
"""
extract_melody.py — song -> vocal melody pitch track -> notes.json for Held.

Pipeline:
  1. Demucs separates the vocal stem from the full mix (skippable if the
     input is already a cappella / monophonic).
  2. librosa pYIN tracks pitch on the isolated vocal.
  3. Post-processing: confidence gate, median smoothing, gap bridging,
     note segmentation.
  4. Writes notes.json: both the raw frame-level track (for the trace
     overlay) and segmented notes (for the target lane + scoring).

Usage:
  python3 extract_melody.py song.mp3
  python3 extract_melody.py vocals.wav --skip-separation
  python3 extract_melody.py song.mp3 -o mysong.json --keep-stems

  # live capture: record from an input device, then run the pipeline.
  python3 extract_melody.py --list-devices
  python3 extract_melody.py --record -o song.json               # mic, Ctrl+C to stop
  python3 extract_melody.py --record --device "BlackHole 2ch" -o song.json

  BlackHole (free virtual audio device) is the clean path for streaming
  sources: set macOS output to a multi-output device (speakers +
  BlackHole), play the song, record from the BlackHole input — a
  digital copy with no room noise. Recording from the physical mic
  works too, just with degraded separation quality.

Requires:
  pip install demucs librosa soundfile sounddevice
  (demucs pulls torch — first install is a few GB; separation runs
   locally, ~30-60s per song on Apple silicon)
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np


# ------------------------------------------------------------------ recording
def list_devices():
    import sounddevice as sd

    print(sd.query_devices())
    print("\nInput devices can be selected with --device <name or index>.")
    print('A "BlackHole" device here means you can capture system audio.')


def record_audio(device, duration, out_path: Path) -> Path:
    """Record from an input device to a wav. Fixed duration, or until
    Ctrl+C if duration is None."""
    import sounddevice as sd
    import soundfile as sf

    sr = 44100
    chunks = []

    def callback(indata, frames, time_info, status):
        if status:
            print(status, file=sys.stderr)
        chunks.append(indata.copy())

    try:
        dev_info = sd.query_devices(device, "input") if device is not None \
            else sd.query_devices(kind="input")
    except (sd.PortAudioError, ValueError) as e:
        sys.exit(
            f"no usable input device ({e}) — run --list-devices to see "
            "what's available"
        )
    print(f"[0/3] recording from: {dev_info['name']}")
    print("      " + (f"{duration:.0f}s…" if duration else "Ctrl+C to stop…"))

    try:
        with sd.InputStream(
            samplerate=sr, channels=1, device=device, callback=callback
        ):
            if duration:
                sd.sleep(int(duration * 1000))
            else:
                while True:
                    sd.sleep(250)
    except KeyboardInterrupt:
        print("\n      stopped")

    if not chunks:
        sys.exit("no audio captured")
    audio = np.concatenate(chunks)
    sf.write(str(out_path), audio, sr)
    secs = len(audio) / sr
    peak = float(np.abs(audio).max())
    print(f"      captured {secs:.1f}s (peak {peak:.2f})")
    if peak < 0.05:
        print(
            "      WARNING: very low signal — check input device / volume.",
            file=sys.stderr,
        )
    return out_path



# ---------------------------------------------------------------- separation
def ensure_stereo(path: Path) -> Path:
    """Demucs upmixes mono via tensor.expand(), then does in-place math on
    the view — a hard error under torch 2.x ("more than one element of the
    written-to tensor refers to a single memory location"). Feed it real
    stereo: duplicate the channel to a sibling file when input is mono.
    Non-wav/flac inputs (mp3 etc.) pass through — commercial mixes are
    stereo already."""
    try:
        import soundfile as sf
        data, sr = sf.read(str(path), always_2d=True)
    except Exception:
        return path
    if data.shape[1] >= 2:
        return path
    stereo = path.with_name(path.stem + ".stereo.wav")
    sf.write(str(stereo), np.repeat(data, 2, axis=1), sr)
    print(f"      mono input — wrote stereo copy {stereo.name} for demucs")
    return stereo


def separate_vocals(input_path: Path, keep_stems: bool):
    """Run Demucs two-stem separation, return (vocals.wav, no_vocals.wav)."""
    out_dir = (
        input_path.parent / "stems"
        if keep_stems
        else Path(tempfile.mkdtemp(prefix="held_demucs_"))
    )
    print(f"[1/3] Demucs separation -> {out_dir}")
    result = subprocess.run(
        [
            sys.executable, "-m", "demucs",
            "--two-stems=vocals",
            "-o", str(out_dir),
            str(input_path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(f"demucs failed (exit {result.returncode})")

    candidates = list(out_dir.rglob("vocals.wav"))
    if not candidates:
        sys.exit(f"demucs produced no vocals.wav under {out_dir}")
    backing = list(out_dir.rglob("no_vocals.wav"))
    return candidates[0], (backing[0] if backing else None)


# ------------------------------------------------------------- pitch tracking
def track_pitch(vocal_path: Path):
    """pYIN on the vocal stem. Returns (times, midi_float_or_nan, voiced_prob)."""
    import librosa

    print(f"[2/3] pYIN pitch tracking on {vocal_path.name}")
    y, sr = librosa.load(str(vocal_path), sr=22050, mono=True)

    f0, voiced_flag, voiced_prob = librosa.pyin(
        y,
        fmin=librosa.note_to_hz("C2"),   # ~65 Hz
        fmax=librosa.note_to_hz("C6"),   # ~1047 Hz
        sr=sr,
        frame_length=2048,
    )
    hop = 512
    times = librosa.frames_to_time(np.arange(len(f0)), sr=sr, hop_length=hop)

    midi = np.full_like(f0, np.nan)
    voiced = ~np.isnan(f0)
    midi[voiced] = librosa.hz_to_midi(f0[voiced])

    # loudness envelope on the same frame grid, normalized so the app
    # can shape synth amplitude by the singer's actual energy contour
    rms = librosa.feature.rms(y=y, frame_length=2048, hop_length=hop)[0]
    n = min(len(rms), len(f0))
    rms, times, midi = rms[:n], times[:n], midi[:n]
    voiced_prob = voiced_prob[:n]
    ref = np.percentile(rms[rms > 0], 95) if np.any(rms > 0) else 1.0
    rms = np.clip(rms / max(ref, 1e-9), 0, 1)

    return times, midi, np.nan_to_num(voiced_prob, nan=0.0), rms


# ------------------------------------------------------------ post-processing
def median_smooth(midi: np.ndarray, k: int = 5) -> np.ndarray:
    """Median filter that ignores NaNs; kills single-frame spikes."""
    out = midi.copy()
    half = k // 2
    for i in range(len(midi)):
        if np.isnan(midi[i]):
            continue
        window = midi[max(0, i - half): i + half + 1]
        window = window[~np.isnan(window)]
        if len(window):
            out[i] = np.median(window)
    return out


def bridge_gaps(midi: np.ndarray, times: np.ndarray, max_gap_s: float = 0.06):
    """Fill short unvoiced gaps between voiced regions (consonants,
    glottal stops) by linear interpolation so notes don't fragment."""
    out = midi.copy()
    n = len(midi)
    i = 0
    while i < n:
        if not np.isnan(out[i]):
            i += 1
            continue
        start = i
        while i < n and np.isnan(out[i]):
            i += 1
        end = i  # first voiced after gap (or n)
        if start == 0 or end == n:
            continue
        if times[end] - times[start - 1] <= max_gap_s:
            out[start:end] = np.interp(
                times[start:end],
                [times[start - 1], times[end]],
                [out[start - 1], out[end]],
            )
    return out


def viterbi_notes(
    midi: np.ndarray,
    times: np.ndarray,
    lo: int = 36,
    hi: int = 84,
    deadband: float = 0.25,
    switch_cost: float = 3.0,
    dist_cost: float = 0.05,
    min_note_s: float = 0.10,
):
    """Decode the frame pitch track into notes via Viterbi over semitone
    states: deviating from a state is cheap inside the deadband (vibrato
    is free), switching states costs enough that scoops and wobble get
    absorbed while genuine note changes do not. Globally optimal, unlike
    greedy splitting — the difference between 8 clean notes and 11
    fragments on the same sung phrase."""
    hop = float(times[1] - times[0]) if len(times) > 1 else 0.023
    states = np.arange(lo, hi + 1)
    S = len(states)
    notes = []

    voiced = ~np.isnan(midi)
    n = len(midi)
    i = 0
    while i < n:
        if not voiced[i]:
            i += 1
            continue
        j = i
        while j < n and voiced[j]:
            j += 1
        run = midi[i:j]
        T = len(run)
        dev = np.abs(run[:, None] - states[None, :]) - deadband
        emit = np.maximum(dev, 0) ** 2
        ds = np.abs(states[:, None] - states[None, :])
        trans = np.where(ds == 0, 0.0, switch_cost + dist_cost * ds)

        cost = emit[0].copy()
        back = np.zeros((T, S), dtype=np.int32)
        for t in range(1, T):
            total = cost[:, None] + trans
            back[t] = np.argmin(total, axis=0)
            cost = total[back[t], np.arange(S)] + emit[t]
        path = np.zeros(T, dtype=np.int32)
        path[-1] = int(np.argmin(cost))
        for t in range(T - 2, -1, -1):
            path[t] = back[t + 1][path[t + 1]]

        k = 0
        while k < T:
            m = k
            while m < T and path[m] == path[k]:
                m += 1
            notes.append(
                {
                    "start": round(float(times[i + k]), 3),
                    "end": round(float(times[i + m - 1] + hop), 3),
                    "midi": int(states[path[k]]),
                    "midi_float": round(float(np.median(run[k:m])), 2),
                }
            )
            k = m
        i = j

    # absorb sub-minimum fragments into the longer adjacent note
    def dur(x):
        return x["end"] - x["start"]

    changed = True
    while changed:
        changed = False
        for k, nte in enumerate(notes):
            if dur(nte) >= min_note_s:
                continue
            prev = (
                notes[k - 1]
                if k > 0 and abs(notes[k - 1]["end"] - nte["start"]) < 0.05
                else None
            )
            nxt = (
                notes[k + 1]
                if k + 1 < len(notes) and abs(notes[k + 1]["start"] - nte["end"]) < 0.05
                else None
            )
            host = prev if (prev and (not nxt or dur(prev) >= dur(nxt))) else nxt
            if host is None:
                notes.pop(k)
            elif host is prev:
                prev["end"] = nte["end"]
                notes.pop(k)
            else:
                nxt["start"] = nte["start"]
                notes.pop(k)
            changed = True
            break

    # merge same-pitch adjacents across small gaps
    out = [notes[0]] if notes else []
    for nte in notes[1:]:
        prev = out[-1]
        if nte["midi"] == prev["midi"] and nte["start"] - prev["end"] <= 0.12:
            prev["end"] = nte["end"]
            prev["midi_float"] = round((prev["midi_float"] + nte["midi_float"]) / 2, 2)
        else:
            out.append(nte)
    return out


def extend_notes_by_activity(
    notes,
    times: np.ndarray,
    rms: np.ndarray,
    threshold: float = 0.06,
    max_ext_s: float = 0.45,
    max_dropout_frames: int = 3,
):
    """Add vstart/vend to each note: the note's boundaries pushed outward
    through contiguous voice ACTIVITY (RMS above threshold). Pitch only
    exists on vowels; the word audibly starts at the consonant and can
    trail off breathy. vstart/vend track the word, start/end stay the
    scoreable pitched core — the app draws the former, scores the latter."""
    if not len(times):
        return notes
    hop = float(times[1] - times[0]) if len(times) > 1 else 0.023
    active = rms > threshold

    def idx(t):
        return int(max(0, min(len(times) - 1, round((t - times[0]) / hop))))

    for i, note in enumerate(notes):
        lo_limit = notes[i - 1]["end"] if i > 0 else 0.0
        hi_limit = notes[i + 1]["start"] if i + 1 < len(notes) else times[-1] + hop

        k = idx(note["start"])
        vstart = note["start"]
        dropout = 0
        while (
            k - 1 >= 0
            and times[k - 1] >= lo_limit
            and note["start"] - times[k - 1] <= max_ext_s
        ):
            if active[k - 1]:
                dropout = 0
                k -= 1
                vstart = times[k]
            elif dropout < max_dropout_frames:
                dropout += 1
                k -= 1
            else:
                break

        k = idx(note["end"])
        vend = note["end"]
        dropout = 0
        while (
            k + 1 < len(times)
            and times[k + 1] + hop <= hi_limit
            and times[k + 1] - note["end"] <= max_ext_s
        ):
            if active[k + 1]:
                dropout = 0
                k += 1
                vend = times[k] + hop
            elif dropout < max_dropout_frames:
                dropout += 1
                k += 1
            else:
                break

        if vstart < note["start"] - 1e-3:
            note["vstart"] = round(float(vstart), 3)
        if vend > note["end"] + 1e-3:
            note["vend"] = round(float(vend), 3)
    return notes



def coverage_report(notes, times: np.ndarray, rms: np.ndarray,
                    threshold: float = 0.06, min_gap_s: float = 0.3):
    """How much of the audible vocal is covered by notes? Prints the
    largest uncovered active spans so missing coverage can be located
    in the audio by timestamp."""
    if not len(times) or not notes:
        return
    hop = float(times[1] - times[0]) if len(times) > 1 else 0.023
    active = rms > threshold
    covered = np.zeros(len(times), dtype=bool)
    for n in notes:
        a = int(max(0, (n.get("vstart", n["start"]) - times[0]) / hop))
        b = int(min(len(times), (n.get("vend", n["end"]) - times[0]) / hop + 1))
        covered[a:b] = True
    miss = active & ~covered
    total_active = active.sum() * hop
    if total_active <= 0:
        return
    pct = 100 * (1 - miss.sum() / max(1, active.sum()))
    spans = []
    i = 0
    while i < len(miss):
        if not miss[i]:
            i += 1
            continue
        j = i
        while j < len(miss) and miss[j]:
            j += 1
        if (j - i) * hop >= min_gap_s:
            spans.append((times[i], (j - i) * hop))
        i = j
    print(f"  coverage: {pct:.0f}% of audible vocal has a note")
    for t0, d in sorted(spans, key=lambda x: -x[1])[:5]:
        print(f"    uncovered: {t0:6.1f}s  ({d:.1f}s of voice, no note)")


def encode_vocal_clip(src: Path, out_audio: Path, peak_target: float = 0.9,
                      mono: bool = True, bitrate: int = 64000) -> bool:
    """Peak-normalize a stem and encode to AAC for the app. afconvert
    ships with macOS; ffmpeg is the fallback. Backing keeps stereo and a
    lower peak so the vocal sits on top in Both mode."""
    import soundfile as sf
    try:
        data, sr = sf.read(str(src), always_2d=True)
    except Exception as e:
        print(f"      audio encode skipped ({e})", file=sys.stderr)
        return False
    if mono:
        data = data.mean(axis=1)
    peak = float(np.abs(data).max()) or 1.0
    data = data * (peak_target / peak)
    tmp = out_audio.with_suffix(".norm.wav")
    sf.write(str(tmp), data, sr)
    for cmd in (
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", str(bitrate),
         str(tmp), str(out_audio)],
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(tmp),
         "-c:a", "aac", "-b:a", f"{bitrate // 1000}k", str(out_audio)],
    ):
        try:
            r = subprocess.run(cmd, capture_output=True)
            if r.returncode == 0 and out_audio.exists():
                tmp.unlink(missing_ok=True)
                return True
        except FileNotFoundError:
            continue
    tmp.unlink(missing_ok=True)
    print("      audio encode failed (need afconvert or ffmpeg)",
          file=sys.stderr)
    return False


# ----------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="Extract vocal melody to notes.json")
    ap.add_argument(
        "input", type=Path, nargs="?", default=None,
        help="song file (mp3/wav/m4a/flac); omit when using --record",
    )
    ap.add_argument("-o", "--output", type=Path, default=None)
    ap.add_argument(
        "--record", action="store_true",
        help="record from an input device instead of reading a file",
    )
    ap.add_argument(
        "--duration", type=float, default=None,
        help="recording length in seconds (default: until Ctrl+C)",
    )
    ap.add_argument(
        "--device", default=None,
        help="input device name or index for --record (see --list-devices)",
    )
    ap.add_argument(
        "--list-devices", action="store_true",
        help="list audio devices and exit",
    )
    ap.add_argument(
        "--skip-separation",
        action="store_true",
        help="input is already a vocal / monophonic track",
    )
    ap.add_argument(
        "--keep-stems",
        action="store_true",
        help="keep demucs stems next to the input instead of a temp dir",
    )
    ap.add_argument(
        "--no-audio", action="store_true",
        help="skip encoding the vocal stem clip for the app",
    )
    ap.add_argument(
        "--min-confidence",
        type=float,
        default=0.35,
        help="drop frames below this voiced probability (default 0.35; "
             "Viterbi decoding tolerates noisy frames, so keep this low "
             "for coverage)",
    )
    args = ap.parse_args()

    if args.list_devices:
        list_devices()
        return

    if args.record:
        if args.input is not None:
            sys.exit("--record takes no input file")
        device = args.device
        if device is not None and device.isdigit():
            device = int(device)
        stem = (
            args.output.stem.replace(".notes", "")
            if args.output
            else "recording"
        )
        args.input = Path(f"{stem}.wav")
        record_audio(device, args.duration, args.input)
    elif args.input is None:
        ap.error("provide an input file or use --record")

    if not args.input.exists():
        sys.exit(f"no such file: {args.input}")
    out_path = args.output or args.input.with_suffix(".notes.json")

    if args.skip_separation:
        vocal_path, backing_path = args.input, None
    else:
        vocal_path, backing_path = separate_vocals(
            ensure_stereo(args.input), args.keep_stems)

    times, midi, conf, rms = track_pitch(vocal_path)

    # confidence gate, then smooth, then bridge
    midi[conf < args.min_confidence] = np.nan
    midi = median_smooth(midi, k=5)
    midi = bridge_gaps(midi, times)

    notes = extend_notes_by_activity(viterbi_notes(midi, times), times, rms)
    coverage_report(notes, times, rms)

    print("[3/3] writing JSON")
    frames = {
        "t": [round(float(t), 3) for t in times],
        "midi": [None if np.isnan(m) else round(float(m), 2) for m in midi],
        "rms": [round(float(r), 3) for r in rms],
    }
    doc = {
        "source": args.input.name,
        "hop_s": round(float(times[1] - times[0]), 5) if len(times) > 1 else None,
        "notes": notes,
        "frames": frames,
    }
    out_path.write_text(json.dumps(doc))

    if not args.no_audio:
        stem = out_path.name
        for suf in (".notes.json", ".json"):
            if stem.endswith(suf):
                stem = stem[: -len(suf)]
                break
        audio_out = out_path.with_name(stem + ".vocals.m4a")
        if encode_vocal_clip(vocal_path, audio_out):
            kb = audio_out.stat().st_size // 1024
            print(f"  vocal clip: {audio_out.name} ({kb} KB)")
        if backing_path is not None:
            backing_out = out_path.with_name(stem + ".backing.m4a")
            if encode_vocal_clip(backing_path, backing_out, peak_target=0.7,
                                 mono=False, bitrate=96000):
                kb = backing_out.stat().st_size // 1024
                print(f"  backing clip: {backing_out.name} ({kb} KB)")

    voiced_pct = 100 * np.count_nonzero(~np.isnan(midi)) / max(1, len(midi))
    if notes:
        lo = min(n["midi"] for n in notes)
        hi = max(n["midi"] for n in notes)
        names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        rng = (
            f"{names[lo % 12]}{lo // 12 - 1}"
            f" – {names[hi % 12]}{hi // 12 - 1}"
        )
    else:
        rng = "n/a"
    print(
        f"done: {out_path}\n"
        f"  duration: {times[-1]:.1f}s | voiced: {voiced_pct:.0f}% | "
        f"notes: {len(notes)} | range: {rng}"
    )


if __name__ == "__main__":
    main()
