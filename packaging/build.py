"""Builds the npm package and the PyPI wheels from `zig build release` output.

    zig build release
    python packaging/build.py --version 0.2.0 [--out dist-packages]

Produces, in --out:
    npm/                        the npm package directory (`npm pack` / `npm publish` it)
    zig_anything-<v>-py3-none-<platform>.whl   one wheel per release target

Standard library only. Wheels are zip files with the metadata pip expects;
each holds the binary for one platform and a `zig-anything` console script.
"""
import argparse
import base64
import csv
import hashlib
import io
import json
import os
import shutil
import stat
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# zig triple (directory under zig-out/release) -> wheel platform tag
WHEEL_TAGS = {
    # Static musl binaries run on glibc and musl distributions alike.
    "x86_64-linux-musl": "manylinux_2_17_x86_64.manylinux2014_x86_64.musllinux_1_1_x86_64",
    "aarch64-linux-musl": "manylinux_2_17_aarch64.manylinux2014_aarch64.musllinux_1_1_aarch64",
    "x86_64-macos": "macosx_10_12_x86_64",
    "aarch64-macos": "macosx_11_0_arm64",
    "x86_64-windows": "win_amd64",
    "aarch64-windows": "win_arm64",
}

DESCRIPTION = "Port JavaScript, TypeScript and Python code to Zig one piece at a time, and prove every port behaves exactly like the original."


def exe_name(triple):
    return "zig-anything.exe" if "windows" in triple else "zig-anything"


def find_binaries(release_dir):
    found = {}
    for triple in WHEEL_TAGS:
        # zig may add an ABI suffix to the directory name (x86_64-windows-gnu).
        for name in sorted(os.listdir(release_dir)):
            if name == triple or name.startswith(triple + "-"):
                path = os.path.join(release_dir, name, exe_name(triple))
                if os.path.isfile(path):
                    found[triple] = path
                    break
    missing = [t for t in WHEEL_TAGS if t not in found]
    if missing:
        sys.exit(f"missing release binaries for {', '.join(missing)}; run `zig build release` first")
    return found


# ---------------------------------------------------------------- npm

def build_npm(binaries, version, out):
    pkg = os.path.join(out, "npm")
    shutil.rmtree(pkg, ignore_errors=True)
    os.makedirs(os.path.join(pkg, "bin"))
    shutil.copy(os.path.join(ROOT, "packaging", "npm", "zig-anything.js"), os.path.join(pkg, "bin", "zig-anything.js"))
    for triple, path in binaries.items():
        dst = os.path.join(pkg, "binaries", triple)
        os.makedirs(dst)
        shutil.copy(path, os.path.join(dst, exe_name(triple)))
        os.chmod(os.path.join(dst, exe_name(triple)), 0o755)
    for name in ("README.md", "LICENSE", "CHANGELOG.md"):
        shutil.copy(os.path.join(ROOT, name), pkg)
    manifest = {
        "name": "zig-anything",
        "version": version,
        "description": DESCRIPTION,
        "license": "MIT",
        "repository": {"type": "git", "url": "git+https://github.com/Layfate/zig-anything.git"},
        "homepage": "https://github.com/Layfate/zig-anything#readme",
        "keywords": ["zig", "migration", "port", "differential-testing", "mcp", "napi"],
        "bin": {"zig-anything": "bin/zig-anything.js"},
        "files": ["bin", "binaries", "README.md", "LICENSE", "CHANGELOG.md"],
        "os": ["linux", "darwin", "win32"],
        "cpu": ["x64", "arm64"],
        "engines": {"node": ">=18"},
    }
    with open(os.path.join(pkg, "package.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    return pkg


# ---------------------------------------------------------------- wheels

MAIN_PY = '''"""Runs the zig-anything binary shipped in this wheel."""
import os
import subprocess
import sys


def binary():
    name = "zig-anything.exe" if os.name == "nt" else "zig-anything"
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", name)


def main():
    exe = binary()
    if os.name == "nt":
        sys.exit(subprocess.call([exe, *sys.argv[1:]]))
    os.execv(exe, [exe, *sys.argv[1:]])


if __name__ == "__main__":
    main()
'''


def record_line(name, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return [name, f"sha256={digest}", str(len(data))]


def build_wheel(triple, binary, version, out):
    tag = f"py3-none-{WHEEL_TAGS[triple]}"
    dist = f"zig_anything-{version}"
    info = f"{dist}.dist-info"
    with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as f:
        readme = f.read()
    metadata = "\n".join([
        "Metadata-Version: 2.1",
        "Name: zig-anything",
        f"Version: {version}",
        f"Summary: {DESCRIPTION}",
        "Home-page: https://github.com/Layfate/zig-anything",
        "License: MIT",
        "Requires-Python: >=3.8",
        "Description-Content-Type: text/markdown",
        "",
        readme,
    ])
    wheel_meta = "\n".join(["Wheel-Version: 1.0", "Generator: zig-anything packaging/build.py", "Root-Is-Purelib: false", f"Tag: {tag}", ""])
    with open(binary, "rb") as f:
        exe = f.read()
    with open(os.path.join(ROOT, "LICENSE"), "rb") as f:
        license_text = f.read()
    files = [
        ("zig_anything/__init__.py", f'"""zig-anything {version}"""\n__version__ = "{version}"\n'.encode(), 0o644),
        ("zig_anything/__main__.py", MAIN_PY.encode(), 0o644),
        (f"zig_anything/bin/{exe_name(triple)}", exe, 0o755),
        (f"{info}/METADATA", metadata.encode(), 0o644),
        (f"{info}/WHEEL", wheel_meta.encode(), 0o644),
        (f"{info}/entry_points.txt", b"[console_scripts]\nzig-anything = zig_anything.__main__:main\n", 0o644),
        (f"{info}/LICENSE", license_text, 0o644),
    ]
    rows = [record_line(name, data) for name, data, _ in files]
    rows.append([f"{info}/RECORD", "", ""])
    rec = io.StringIO()
    csv.writer(rec, lineterminator="\n").writerows(rows)
    files.append((f"{info}/RECORD", rec.getvalue().encode(), 0o644))

    path = os.path.join(out, f"{dist}-{tag}.whl")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data, mode in files:
            zi = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))  # reproducible
            zi.external_attr = (stat.S_IFREG | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", required=True, help="package version, e.g. 0.2.0 (a leading v is dropped)")
    ap.add_argument("--release-dir", default=os.path.join(ROOT, "zig-out", "release"))
    ap.add_argument("--out", default=os.path.join(ROOT, "dist-packages"))
    args = ap.parse_args()
    version = args.version.lstrip("v")
    binaries = find_binaries(args.release_dir)
    os.makedirs(args.out, exist_ok=True)
    print(f"npm package  {build_npm(binaries, version, args.out)}")
    for triple, binary in binaries.items():
        print(f"wheel        {build_wheel(triple, binary, version, args.out)}")


if __name__ == "__main__":
    main()
