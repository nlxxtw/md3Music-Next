# -*- coding: utf-8 -*-
"""Merge G:\\share\\...\\选择 IRS into viper_local.zip with short display names."""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DST = ROOT / "assets" / "sound_presets"
ZIP_PATH = DST / "viper_local.zip"
SELECT = Path(r"G:\share\音效文的地方帆帆件\选择")
TMP = DST / "_rebuild_select"

# Short formal display names (file stem → UI name)
NAME_MAP = {
    "8D环绕感-宽景": "8D 宽景",
    "8D环绕感-深空": "8D 深空",
    "双耳3D-舞台": "双耳3D 舞台",
    "双耳3D-近场": "双耳3D 近场",
    "3D Headphone HD - Profile 1": "3D Headphone HD 1",
    "3D立体感音效低音炮版": "3D 低音炮",
    "3D耳机 HD - 预设2": "3D 耳机 HD 2",
    "Vox8d": "Vox 8D",
    "HIFI实验（高级）2-13b3": "HiFi 实验高级",
    "HRTF自研环绕": "HRTF 自研环绕",
    "RainSnow Live全景声V5.0": "RainSnow 全景声",
    "Sony Hi-Fi Effect Hall": "Sony Hi-Fi 大厅",
    "Sony Hi-Fi Groove On": "Sony Hi-Fi Groove",
    "Sony Xperia ((128K MP3)) Clear bass MAX": "Sony Clear Bass MAX",
    "Sony Xperia VPT 1.Studio": "Sony VPT Studio",
    "Srchy｛DTS｝头戴式-前置模式 4声道": "DTS 头戴前置",
    "super sound环绕": "Super Sound 环绕",
    "XHR q-环绕声": "XHR 环绕声",
    "XHR 保真之源 (母带级)": "XHR 保真之源",
    "XHR 动态低音 - 扬声器 (极限)": "XHR 动态低音",
    "XHR 极致HiFi+": "XHR 极致 HiFi+",
    "XHR 极限重低音 (扬声器)": "XHR 极限重低音",
    "XHR 至臻音效 HE": "XHR 至臻 HE",
    "三星5.1立体声": "三星 5.1",
    "人声环绕": "人声环绕",
    "低音扬声器": "低音扬声器",
    "哈曼音效脉冲": "哈曼音效",
    "最强混合-13": "最强混合",
    "极致HiFi": "极致 HiFi",
    "极致HiFi脉冲": "极致 HiFi 脉冲",
    "环绕立体_": "环绕立体",
    "环绕立体声": "环绕立体声",
    "索尼醇音+": "索尼醇音+",
    "臻享扬声器+": "臻享扬声器+",
    "臻享高解析+": "臻享高解析+",
    "蝰蛇杜比": "蝰蛇杜比",
    "酷狗3D丽音[重制版]": "酷狗 3D丽音（重制）",
    "酷狗beats耳机音效": "酷狗 Beats 耳机",
    "酷狗megaBass重低音音效": "酷狗 MegaBass",
    "酷狗S-XBS重低音": "酷狗 S-XBS",
    "酷狗SRS-3D": "酷狗 SRS-3D",
    "酷狗TruStadio Pro环绕音效": "酷狗 TruStudio Pro",
    "酷狗声学客厅": "酷狗 声学客厅",
    "酷狗大型露天演唱会": "酷狗 露天演唱会",
    "酷狗差分环绕": "酷狗 差分环绕",
    "酷狗环境虚拟化（大音乐厅）": "酷狗 大音乐厅",
    "酷狗生活房间": "酷狗 生活房间",
    "酷狗纯净人声": "酷狗 纯净人声",
    "酷狗自然低音": "酷狗 自然低音",
    "酷狗蝰蛇频谱扩展技术模拟": "酷狗 蝰蛇频谱扩展",
    "酷狗诺基亚5320XpressMusic音效": "酷狗 诺基亚 5320",
    "酷狗超重低音": "酷狗 超重低音",
}


def file_hash(p: Path) -> str:
    h = hashlib.sha1()
    h.update(p.read_bytes())
    return h.hexdigest()


def guess_tag(name: str) -> str:
    low = name.lower()
    if name.startswith("8D") or "vox8d" in low or "vox 8d" in low:
        return "8D"
    if name.startswith("双耳") or "3d丽音" in low or "hrtf" in low:
        return "双耳3D"
    if "dolby" in low or "atmos" in low or "杜比" in name:
        return "杜比"
    if "srs" in low:
        return "SRS"
    if "dts" in low:
        return "DTS"
    if "sony" in low or "索尼" in name or "xperia" in low:
        return "索尼"
    if "xhr" in low:
        return "XHR"
    if "酷狗" in name:
        return "酷狗"
    if "黑钻" in name or "蝰蛇" in name or "viper" in low:
        return "蝰蛇"
    if "环绕" in name or "surround" in low or "全景" in name or "5.1" in name:
        return "环绕"
    if "hifi" in low or "hi-fi" in low or "母带" in name:
        return "HiFi"
    return "环绕"


def short_name(stem: str) -> str:
    if stem in NAME_MAP:
        return NAME_MAP[stem]
    # keep prior cleaned names / strip junk wrappers
    n = stem
    n = re.sub(r"^EzRlon[-_＿]?", "", n)
    n = re.sub(r"[「」『』〔〕［］\[\]【】｛｝{}]", "", n)
    n = re.sub(r"（.*?）|\(.*?\)", "", n)
    n = re.sub(r"音效移植|移植音效|重制版|清晰度提升", "", n)
    n = re.sub(r"[-_＿]+$", "", n)
    n = re.sub(r"\s+", " ", n).strip(" -_")
    if "】" in stem:
        n = stem.split("】", 1)[-1].strip() or n
    return n or stem


def main() -> None:
    if not SELECT.exists():
        raise SystemExit(f"missing select folder: {SELECT}")
    if TMP.exists():
        shutil.rmtree(TMP)
    TMP.mkdir(parents=True)

    with zipfile.ZipFile(ZIP_PATH, "r") as zf:
        zf.extractall(TMP)

    hashes: dict[str, str] = {}
    names: set[str] = set()
    for f in sorted(TMP.iterdir(), key=lambda p: p.name.lower()):
        if not (f.is_file() and f.suffix.lower() in {".irs", ".wav"}):
            continue
        dig = file_hash(f)
        if dig in hashes:
            f.unlink()
            continue
        hashes[dig] = f.name
        names.add(f.name.lower())

    added: list[str] = []
    skipped: list[str] = []
    for src in sorted(SELECT.iterdir(), key=lambda p: p.name.lower()):
        if not src.is_file() or src.suffix.lower() not in {".irs", ".wav"}:
            continue
        dig = file_hash(src)
        if dig in hashes:
            skipped.append(f"{src.name} (content= {hashes[dig]})")
            continue
        if src.name.lower() in names:
            skipped.append(f"{src.name} (name exists)")
            continue
        dest = TMP / src.name
        shutil.copy2(src, dest)
        hashes[dig] = src.name
        names.add(src.name.lower())
        added.append(src.name)
        print("added", src.name)

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
        name = short_name(stem)
        manifest.append(
            {
                "id": i,
                "file": p.name,
                "name": name,
                "fullName": name,
                "tag": guess_tag(name if name else stem),
            }
        )
    (DST / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    new_zip = DST / "viper_local_new.zip"
    if new_zip.exists():
        new_zip.unlink()
    with zipfile.ZipFile(new_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in files:
            zf.write(p, p.name)
    ZIP_PATH.unlink()
    new_zip.rename(ZIP_PATH)
    shutil.rmtree(TMP)
    print("manifest", len(manifest))
    print("added_count", len(added))
    print("skipped_count", len(skipped))
    for s in skipped[:30]:
        print("skip", s)
    print("zip_mb", round(ZIP_PATH.stat().st_size / 1024 / 1024, 2))


if __name__ == "__main__":
    main()
