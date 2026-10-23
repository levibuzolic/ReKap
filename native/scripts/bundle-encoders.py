#!/usr/bin/env python3
"""Copy FFmpeg and its non-system Mach-O dependencies into an application.

Usage: bundle-encoders.py /path/ReKap.app [--ffmpeg /opt/homebrew/bin/ffmpeg]
All executable dependencies are rewritten to app-local paths and ad-hoc signed.
This Homebrew FFmpeg build uses GPL codecs. Distributors must supply corresponding
source, build instructions and license notices for FFmpeg and bundled libraries.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(path):
    return [line.strip().rsplit(" (", 1)[0]
            for line in run("otool", "-L", str(path)).splitlines()[1:]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--ffmpeg", type=Path, default=Path(os.environ.get("REKAP_FFMPEG", "/opt/homebrew/bin/ffmpeg")))
    args = parser.parse_args()
    if not args.ffmpeg.is_file():
        raise SystemExit("Install Homebrew FFmpeg or provide --ffmpeg.")
    required_encoders = {"libx264", "libx265", "libvpx-vp9", "libsvtav1", "libopus", "aac", "gif", "apng", "png"}
    required_filters = {"fps", "scale", "setsar", "palettegen", "paletteuse"}
    for option, required in [("-encoders", required_encoders), ("-filters", required_filters)]:
        available = {parts[1] for line in run(str(args.ffmpeg), "-hide_banner", option).splitlines()
                     if len(parts := line.split()) >= 2}
        missing = sorted(required - available)
        if missing:
            raise SystemExit(f"FFmpeg {option} missing required capabilities: {', '.join(missing)}")
    helpers = args.app / "Contents/Helpers"
    libraries = args.app / "Contents/Frameworks/Encoders"
    notices = args.app / "Contents/Resources/EncoderLicenses"
    for directory in [helpers, libraries, notices]:
        directory.mkdir(parents=True, exist_ok=True)
    copied = {}
    pending = [(args.ffmpeg.resolve(), helpers / "ffmpeg")]
    manifest = []
    while pending:
        original, target = pending.pop()
        original = original.resolve()
        if original in copied:
            continue
        copied[original] = target
        shutil.copy2(original, target)
        target.chmod(0o755)
        for dependency in dependencies(original):
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if dependency.startswith("@"):
                # Homebrew generally uses absolute install names. Resolve loader
                # relative names; fail explicitly rather than ship broken helpers.
                if dependency.startswith("@loader_path/"):
                    source = original.parent / dependency.removeprefix("@loader_path/")
                elif dependency.startswith("@rpath/"):
                    source = original.parent / Path(dependency).name
                else:
                    raise SystemExit(f"Unresolved dependency {dependency} in {original}")
            else:
                source = Path(dependency)
            source = source.resolve()
            if not source.is_file():
                raise SystemExit(f"Missing dependency {dependency} in {original}")
            destination = libraries / source.name
            collision = next((key for key, value in copied.items() if value == destination and key != source), None)
            if collision:
                raise SystemExit(f"Library filename collision: {source} and {collision}")
            local = ("@loader_path/../Frameworks/Encoders/" if target.parent == helpers else "@loader_path/") + source.name
            subprocess.run(["install_name_tool", "-change", dependency, local, str(target)], check=True)
            pending.append((source, destination))
        if target.parent == libraries:
            subprocess.run(["install_name_tool", "-id", "@loader_path/" + target.name, str(target)], check=True)
        manifest.append({"source": str(original), "bundled": str(target.relative_to(args.app))})
        # Homebrew keeps each formula's upstream license files in its keg root.
        cellar = original.parts
        if "Cellar" in cellar:
            index = cellar.index("Cellar")
            keg = Path(*cellar[:index + 3])
            formula = cellar[index + 1]
            for license_file in keg.iterdir():
                if license_file.is_file() and license_file.name.upper().startswith(("COPYING", "LICENSE", "AUTHORS", "NOTICE")):
                    license_destination = notices / formula
                    license_destination.mkdir(exist_ok=True)
                    shutil.copy2(license_file, license_destination / license_file.name)
    for original, target in copied.items():
        subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
    (notices / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    configuration = run(str(helpers / "ffmpeg"), "-hide_banner", "-buildconf")
    (notices / "ffmpeg-buildconf.txt").write_text(configuration + "\n")
    print(f"Bundled FFmpeg and {len(copied) - 1} libraries into {args.app}")


if __name__ == "__main__":
    main()
