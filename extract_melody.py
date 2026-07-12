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


def separate_vocals(input_path: Path, keep_stems: bool) -> Path:
    """Run Demucs two-stem separation, return path to vocals.wav."""
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
    return candidates[0]


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
    return times, midi, np.nan_to_num(voiced_prob, nan=0.0)


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


def segment_notes(
    midi: np.ndarray,
    times: np.ndarray,
    split_semitones: float = 0.6,
    min_note_s: float = 0.08,
):
    """Split the frame track into note segments on pitch jumps or
    unvoiced gaps. Returns list of dicts."""
    notes = []
    seg_start = None
    seg_frames = []

    def flush(end_idx):
        nonlocal seg_start, seg_frames
        if seg_start is None or not seg_frames:
            seg_start, seg_frames = None, []
            return
        start_t = times[seg_start]
        end_t = times[end_idx]
        if end_t - start_t >= min_note_s:
            arr = np.array(seg_frames)
            notes.append(
                {
                    "start": round(float(start_t), 3),
                    "end": round(float(end_t), 3),
                    "midi": int(np.round(np.median(arr))),
                    "midi_float": round(float(np.median(arr)), 2),
                }
            )
        seg_start, seg_frames = None, []

    for i in range(len(midi)):
        if np.isnan(midi[i]):
            flush(i - 1 if i > 0 else 0)
            continue
        if seg_start is None:
            seg_start = i
            seg_frames = [midi[i]]
            continue
        if abs(midi[i] - np.median(seg_frames)) > split_semitones:
            flush(i - 1)
            seg_start = i
            seg_frames = [midi[i]]
        else:
            seg_frames.append(midi[i])
    flush(len(midi) - 1)
    return notes


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
        "--min-confidence",
        type=float,
        default=0.5,
        help="drop frames below this voiced probability (default 0.5)",
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

    vocal_path = (
        args.input
        if args.skip_separation
        else separate_vocals(ensure_stereo(args.input), args.keep_stems)
    )

    times, midi, conf = track_pitch(vocal_path)

    # confidence gate, then smooth, then bridge
    midi[conf < args.min_confidence] = np.nan
    midi = median_smooth(midi, k=5)
    midi = bridge_gaps(midi, times)

    notes = segment_notes(midi, times)

    print("[3/3] writing JSON")
    frames = {
        "t": [round(float(t), 3) for t in times],
        "midi": [None if np.isnan(m) else round(float(m), 2) for m in midi],
    }
    doc = {
        "source": args.input.name,
        "hop_s": round(float(times[1] - times[0]), 5) if len(times) > 1 else None,
        "notes": notes,
        "frames": frames,
    }
    out_path.write_text(json.dumps(doc))

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
