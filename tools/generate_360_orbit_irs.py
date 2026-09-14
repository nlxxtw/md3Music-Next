# -*- coding: utf-8 -*-
"""Generate clean asymmetric 4ch HRTF-style IRs for 360/8D orbit presets.

Channel order (EchoMusic): LL, LR, RL, RR
These are short, low-noise early responses with ITD/ILD — not long noisy tails.
Runtime L↔R orbit is applied in ConvolutionAudioProcessor.
"""
from __future__ import annotations

import math
import struct
import wave
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DST = ROOT / "assets" / "sound_presets"
ZIP_PATH = DST / "viper_local.zip"
TMP = DST / "_orbit_gen"
SR = 48000


def write_wav_4ch(path: Path, ll, lr, rl, rr) -> None:
    n = len(ll)
    frames = bytearray()
    for i in range(n):
        for v in (ll[i], lr[i], rl[i], rr[i]):
            s = max(-1.0, min(1.0, v))
            frames += struct.pack("<h", int(round(s * 32767.0)))
    with wave.open(str(path), "w") as w:
        w.setnchannels(4)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)


def impulse_pair(
    duration_s: float,
    itd_l_ms: float,
    itd_r_ms: float,
    ild_db: float,
    decay: float,
    room: float,
    brightness: float,
) -> tuple[list[float], list[float], list[float], list[float]]:
    n = int(SR * duration_s)
    ll = [0.0] * n
    lr = [0.0] * n
    rl = [0.0] * n
    rr = [0.0] * n

    def place(buf: list[float], delay_ms: float, amp: float) -> None:
        d = int(round(delay_ms * SR / 1000.0))
        if 0 <= d < n:
            buf[d] += amp
        # shorter / quieter pinna taps — keep HF clearer
        for k, a in ((0.12, 0.14), (0.28, 0.07)):
            j = d + int(k * SR / 1000.0)
            if 0 <= j < n:
                buf[j] += amp * a * brightness

    # Keep LL/RR closer in level so orbit doesn't fight a lopsided matrix
    gain_l = 10 ** (ild_db / 40.0)
    gain_r = 10 ** (-ild_db / 40.0)
    place(ll, itd_l_ms, 1.0 * gain_l)
    place(rr, itd_r_ms, 1.0 * gain_r)
    place(lr, itd_l_ms + 0.22, 0.18 * gain_r)
    place(rl, itd_r_ms + 0.22, 0.18 * gain_l)

    reflections = [
        (5.5, 0.10),
        (10.0, 0.06),
        (16.0, 0.04),
        (22.0, 0.025),
    ]
    for ms, a in reflections:
        amp = a * room
        place(ll, ms + itd_l_ms * 0.25, amp * gain_l)
        place(rr, ms + itd_r_ms * 0.25, amp * gain_r)
        place(lr, ms + 0.3 + itd_l_ms * 0.15, amp * 0.4 * gain_r)
        place(rl, ms + 0.3 + itd_r_ms * 0.15, amp * 0.4 * gain_l)

    for i in range(n):
        env = math.exp(-decay * i / SR)
        ll[i] *= env
        lr[i] *= env
        rl[i] *= env
        rr[i] *= env

    # Very light smooth only (old 0.72/0.28 killed treble → muddy)
    def smooth(buf: list[float]) -> None:
        prev = 0.0
        for i in range(n):
            prev = 0.25 * prev + 0.75 * buf[i]
            buf[i] = prev

    smooth(ll)
    smooth(lr)
    smooth(rl)
    smooth(rr)

    peak = max(abs(v) for seq in (ll, lr, rl, rr) for v in seq) or 1.0
    scale = 0.82 / peak
    for seq in (ll, lr, rl, rr):
        for i in range(n):
            seq[i] *= scale
    return ll, lr, rl, rr


PRESETS = [
    # name, duration, itdL, itdR, ild_db, decay, room, brightness
    ("8D环绕感-宽景.wav", 0.16, 0.10, 0.32, 1.8, 14.0, 0.45, 1.15),
    ("8D环绕感-深空.wav", 0.22, 0.08, 0.38, 2.2, 11.0, 0.55, 1.05),
    ("双耳3D-舞台.wav", 0.18, 0.12, 0.34, 1.5, 12.0, 0.60, 1.10),
    ("双耳3D-近场.wav", 0.10, 0.14, 0.28, 2.5, 18.0, 0.25, 1.20),
]


def main() -> None:
    if TMP.exists():
        import shutil

        shutil.rmtree(TMP)
    TMP.mkdir(parents=True)

    # Extract existing zip
    with zipfile.ZipFile(ZIP_PATH, "r") as zf:
        zf.extractall(TMP)

    for name, dur, itd_l, itd_r, ild, decay, room, bright in PRESETS:
        ll, lr, rl, rr = impulse_pair(dur, itd_l, itd_r, ild, decay, room, bright)
        out = TMP / name
        write_wav_4ch(out, ll, lr, rl, rr)
        print("wrote", name, "samples", len(ll), "bytes", out.stat().st_size)

    # Rebuild zip from all audio in TMP
    files = sorted(
        [
            p
            for p in TMP.iterdir()
            if p.is_file() and p.suffix.lower() in {".irs", ".wav"}
        ],
        key=lambda p: (
            0 if p.name.startswith("8D") else 1 if p.name.startswith("双耳") else 2,
            p.name.lower(),
        ),
    )
    new_zip = DST / "viper_local_new.zip"
    if new_zip.exists():
        new_zip.unlink()
    with zipfile.ZipFile(new_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in files:
            zf.write(p, p.name)
    ZIP_PATH.unlink()
    new_zip.rename(ZIP_PATH)

    # Refresh manifest entries for these four (keep rest via rebuild script style)
    import json

    manifest = []
    for i, p in enumerate(files, 1):
        stem = p.stem
        tag = "环绕"
        low = stem.lower()
        if "8d" in low or "vox8d" in low:
            tag = "8D"
        elif "双耳" in stem or "3d" in low or "headphone" in low:
            tag = "双耳3D"
        elif "dolby" in low or "atmos" in low or "杜比" in stem:
            tag = "杜比"
        elif "srs" in low:
            tag = "SRS"
        elif "dts" in low:
            tag = "DTS"
        elif "黑钻" in stem or "diamond" in low or "viper" in low:
            tag = "蝰蛇"
        name = stem.split("】", 1)[-1].strip() if "】" in stem else stem
        manifest.append(
            {
                "id": i,
                "file": p.name,
                "name": name,
                "fullName": stem,
                "tag": tag,
            }
        )
    (DST / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    import shutil

    shutil.rmtree(TMP)
    print("zip_bytes", ZIP_PATH.stat().st_size, "manifest", len(manifest))


if __name__ == "__main__":
    main()
