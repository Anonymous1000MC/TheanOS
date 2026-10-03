#!/usr/bin/env python3
"""Generate (or verify) Packages/manifest.cfg.

The updater compares these hashes against a copy stored on the device to decide
which files actually changed, so it only downloads those.

Hashing is done HERE, at build time, deliberately. SHA-256 in MineOS is pure
Lua, and the install set is ~2.4 MB with GUI.lua alone at 156 KB -- hashing that
on OpenComputers' throttled VM would take minutes. The device never hashes
anything: it stores the hash it was handed and compares table entries, which is
a plain table lookup per file.

  --check   verify the committed manifest matches the working tree and covers
            every installable path. Run this before pushing: a stale manifest
            ships old code to users, which is the one way this design can break
            silently.
"""
import hashlib
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "Packages", "manifest.cfg")

# The path set that can end up installed at "/". installerFiles is deliberately
# excluded: those are staged in the temporary installer directory, not installed.
LUA_DUMP = r'''
local ld = loadstring or load
local cfg = assert(ld("return " .. io.open("Installer/Files.cfg"):read("*a")))()
local paths, seen = {}, {}
local function add(p)
  if type(p) == "table" then p = p.path end
  if type(p) == "string" and p ~= "" and not seen[p] then seen[p] = true; paths[#paths+1] = p end
end
for _, e in ipairs(cfg.required or {}) do add(e) end
for _, e in ipairs(cfg.requiredWallpapers or {}) do add(e) end
for _, e in ipairs(cfg.optional or {}) do add(e) end
for _, e in ipairs(cfg.optionalWallpapers or {}) do add(e) end
for _, n in ipairs(cfg.localizations or {}) do add("Localizations/" .. n:match("[^/]+$")) end
table.sort(paths)
for _, p in ipairs(paths) do print(p) end
'''

ENTRY = re.compile(r'^\s*\["([^"]+)"\]\s*=\s*"([0-9a-f]{64})",?\s*$')


def installable_paths():
    out = subprocess.run(["lua5.1", "-e", LUA_DUMP], cwd=ROOT,
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("could not read Installer/Files.cfg:\n" + out.stderr)
    return [l.strip() for l in out.stdout.split("\n") if l.strip()]


def digest(rel):
    h = hashlib.sha256()
    with open(os.path.join(ROOT, rel), "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def build(paths):
    files, missing = {}, []
    for rel in paths:
        if not os.path.exists(os.path.join(ROOT, rel)):
            missing.append(rel)
            continue
        files["/" + rel] = digest(rel)

    out = ["{",
           "\tversion = 1,",
           "\tcount = %d," % len(files),
           "\tfiles = {"]
    for path in sorted(files):
        out.append('\t\t["%s"] = "%s",' % (path, files[path]))
    out += ["\t},", "}", ""]
    return "\n".join(out), files, missing


def read_committed():
    """Parse our own output format directly -- no Lua subprocess needed."""
    if not os.path.exists(MANIFEST):
        return {}
    files = {}
    with io.open(MANIFEST, encoding="utf-8") as f:
        for line in f:
            m = ENTRY.match(line)
            if m:
                files[m.group(1)] = m.group(2)
    return files


def main():
    check = "--check" in sys.argv
    paths = installable_paths()
    rendered, files, missing = build(paths)

    if missing:
        print("MISSING FILES (cannot hash): %d" % len(missing))
        for m in missing[:20]:
            print("  " + m)
        return 1

    if check:
        committed = read_committed()
        stale = [p for p, h in files.items() if committed.get(p) != h]
        extra = [p for p in committed if p not in files]

        for p in sorted(stale)[:25]:
            kind = "hash mismatch" if p in committed else "not in committed manifest"
            print("  STALE  %s  (%s)" % (p, kind))
        for p in sorted(extra)[:25]:
            print("  EXTRA  %s  (in manifest, not installable)" % p)

        if stale or extra:
            print("\nmanifest is STALE -- run: python3 Tools/build_manifest.py")
            return 1

        print("manifest OK: %d files, all hashes current, full coverage" % len(files))
        return 0

    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    io.open(MANIFEST, "w", encoding="utf-8").write(rendered)
    total = sum(os.path.getsize(os.path.join(ROOT, p)) for p in paths)
    print("wrote Packages/manifest.cfg: %d files, covering %.2f MB"
          % (len(files), total / 1024 / 1024))
    return 0


sys.exit(main())
