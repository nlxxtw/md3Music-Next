# -*- coding: utf-8 -*-
"""Rebuild viper_local.zip: keep existing + add surround/black packs, skip content/name dupes."""
from __future__ import annotations

import hashlib
import json
import shutil
import zipfile
from pathlib import Path

DST = Path(
    r"C:\Users\china\Downloads\md3Music-rust-local-force\md3Music-rust-local-force\assets\sound_presets"
)
ZIP_PATH = DST / "viper_local.zip"
SURROUND = Path(r"G:\share\音效文的地方帆帆件\_精选_左右环绕")
BLACK = Path(r"G:\share\音效文的地方帆帆件\黑钻蝰蛇音效\黑钻蝰蛇音效")
TMP = DST / "_rebuild"


def file_hash(p: Path) -> str:
    h = hashlib.sha1()
    h.update(p.read_bytes())
    return h.hexdigest()


def display_name(stem: str) -> str:
    if "】" in stem:
        return stem.split("】", 1)[-1].strip() or stem
    return stem


def guess_tag(name: str) -> str:
    low = name.lower()
    if "8d" in low or "vox8d" in low:
        return "8D"
    if "双耳" in name or "3d" in low or "headphone" in low or "耳机3d" in low:
        return "双耳3D"
    if "dolby" in low or "atmos" in low or "杜比" in name:
        return "杜比"
    if "srs" in low:
        return "SRS"
    if "dts" in low:
        return "DTS"
    if "黑钻" in name or "diamond" in low or "viper" in low:
        return "蝰蛇"
    if "环绕" in name or "surround" in low or "全景" in name or "archy" in low:
        return "环绕"
    return "环绕"


def main() -> None:
    if TMP.exists():
        shutil.rmtree(TMP)
    TMP.mkdir(parents=True)

    with zipfile.ZipFile(ZIP_PATH, "r") as zf:
        zf.extractall(TMP)

    # hash -> filename already in pack; drop content-identical extras
    hashes: dict[str, str] = {}
    names = set()
    removed_dupes: list[str] = []
    for f in sorted(TMP.iterdir(), key=lambda p: p.name.lower()):
        if not (f.is_file() and f.suffix.lower() in {".irs", ".wav"}):
            continue
        dig = file_hash(f)
        if dig in hashes:
            removed_dupes.append(f"{f.name} (= {hashes[dig]})")
            f.unlink()
            continue
        hashes[dig] = f.name
        names.add(f.name.lower())

    added: list[str] = []
    skipped: list[str] = []

    candidates: list[Path] = []
    if BLACK.exists():
        candidates.extend(sorted(BLACK.glob("*.irs")))
        candidates.extend(sorted(BLACK.glob("*.wav")))
    if SURROUND.exists():
        candidates.extend(sorted(SURROUND.glob("*.irs")))
        candidates.extend(sorted(SURROUND.glob("*.wav")))

    for src in candidates:
        if not src.is_file():
            continue
        if src.suffix.lower() not in {".irs", ".wav"}:
            skipped.append(f"{src.name} (not audio)")
            continue
        dig = file_hash(src)
        if dig in hashes:
            skipped.append(f"{src.name} (= {hashes[dig]})")
            continue
        if src.name.lower() in names:
            skipped.append(f"{src.name} (name exists)")
            continue
        dest_name = src.name
        dest = TMP / dest_name
        if dest.exists():
            skipped.append(f"{src.name} (dest exists)")
            continue
        shutil.copy2(src, dest)
        hashes[dig] = dest_name
        names.add(dest_name.lower())
        added.append(dest_name)
        print("added", dest_name, src.stat().st_size)

    print("--- removed content dupes ---")
    for s in removed_dupes:
        print("remove", s)
    print("--- skipped ---")
    for s in skipped:
        print("skip", s)

    # rebuild manifest: prioritize 8D/双耳3D first, then others alpha
    files = sorted(
        [p for p in TMP.iterdir() if p.is_file() and p.suffix.lower() in {".irs", ".wav"}],
        key=lambda p: (
            0 if p.name.startswith("8D") else 1 if p.name.startswith("双耳") else 2,
            p.name.lower(),
        ),
    )
    manifest = []
    for i, p in enumerate(files, 1):
        stem = p.stem
        manifest.append(
            {
                "id": i,
                "file": p.name,
                "name": display_name(stem),
                "fullName": stem,
                "tag": guess_tag(stem),
            }
        )
    (DST / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("manifest", len(manifest))

    new_zip = DST / "viper_local_new.zip"
    if new_zip.exists():
        new_zip.unlink()
    with zipfile.ZipFile(new_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in files:
            zf.write(p, p.name)
    ZIP_PATH.unlink()
    new_zip.rename(ZIP_PATH)
    shutil.rmtree(TMP)
    print("zip_bytes", ZIP_PATH.stat().st_size)
    print("added_count", len(added))
    print("removed_dupe_count", len(removed_dupes))


if __name__ == "__main__":
    main()
