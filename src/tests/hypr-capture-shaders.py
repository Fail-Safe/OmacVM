#!/usr/bin/env python3
"""Hyprland's shaders with OmacVM's cm_helpers.glsl compile as with its own.

    hypr-capture-shaders.py GLSL_DIR OURS [JOBS]

GLSL_DIR: Hyprland's src/render/shaders/glsl of the release OURS is made for.
Every fragment shader that includes cm_helpers.glsl is built as Hyprland's
ShaderLoader builds a variant (defines.h replaced by the feature set's
defines, includes from the same folder) for every mix of the colour features
(CM, TONEMAP, ALT_TONEMAP, SDR_MOD, MIRROR, ICC) on two sets of the others,
as GLSL ES 3.00 (how Hyprland builds them) and 3.20, once with Hyprland's
cm_helpers.glsl and once with OURS, and compiled with glslangValidator.
Fails when a variant compiles with Hyprland's file and not with ours, or one
a capture uses does not compile at all. glslang is not the VM's compiler
(Mesa's, through virgl); the VM run covers that.
"""
import concurrent.futures
import itertools
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Hyprland 0.56.2's ShaderLoader::getDefines order
FEATURES = ["USE_RGBA", "USE_DISCARD", "USE_TINT", "USE_ROUNDING", "USE_CM", "USE_TONEMAP", "USE_SDR_MOD",
            "USE_BLUR", "USE_ICC", "USE_MIRROR", "USE_MOTION_BLUR", "USE_BLUR_ALPHA_MASK", "USE_BLUR_MATTE",
            "USE_ALT_TONEMAP"]
COLOUR = ["USE_CM", "USE_TONEMAP", "USE_ALT_TONEMAP", "USE_SDR_MOD", "USE_MIRROR", "USE_ICC"]
BASES = {"plain": set(), "window": {"USE_RGBA", "USE_DISCARD", "USE_TINT", "USE_ROUNDING"}}
VERSIONS = ["300 es", "320 es"]
# what a window's capture copy and a window share use
NEEDED = [{"USE_CM", "USE_MIRROR"}, {"USE_CM", "USE_TONEMAP"}, {"USE_CM", "USE_TONEMAP", "USE_MIRROR"},
          {"USE_CM", "USE_TONEMAP", "USE_ALT_TONEMAP", "USE_MIRROR"}, {"USE_CM", "USE_SDR_MOD", "USE_MIRROR"},
          {"USE_CM", "USE_TONEMAP", "USE_SDR_MOD", "USE_MIRROR"}]


def includes(folder, name, seen):
    with open(os.path.join(folder, name), encoding="utf-8") as f:
        for m in re.finditer(r'^\s*#include\s+"([^"]+)"', f.read(), re.M):
            if m.group(1) not in seen:
                seen.add(m.group(1))
                includes(folder, m.group(1), seen)
    return seen


def build(job):
    work, files, frag, version, feats = job
    d = tempfile.mkdtemp(dir=work)
    for name, path in files.items():
        if name not in (frag, "defines.h"):
            os.symlink(path, os.path.join(d, name))
    with open(os.path.join(d, "defines.h"), "w", encoding="utf-8") as f:
        f.write("".join(f"#define {n} {1 if n in feats else 0}\n" for n in FEATURES))
    with open(files[frag], encoding="utf-8") as f:
        src = f.read()
    with open(os.path.join(d, frag), "w", encoding="utf-8") as f:
        f.write(re.sub(r"^#version 300 es", "#version " + version, src, count=1))
    # As Hyprland: glslang's preprocessor with the includes (looked up from the
    # working folder), "#line" lines dropped, then the GL driver compiles that.
    pre = subprocess.run(["glslangValidator", "-E", "-S", "frag", frag], cwd=d,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if pre.returncode != 0 or "main" not in pre.stdout:
        shutil.rmtree(d, ignore_errors=True)
        return False, pre.stdout
    with open(os.path.join(d, "pre.frag"), "w", encoding="utf-8") as f:
        f.write("".join(l for l in pre.stdout.splitlines(True) if not l.startswith("#line ")))
    r = subprocess.run(["glslangValidator", "-S", "frag", "pre.frag"], cwd=d,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    shutil.rmtree(d, ignore_errors=True)
    return r.returncode == 0, r.stdout


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    glsl, ours = argv[1], argv[2]
    jobs = int(argv[3]) if len(argv) > 3 else os.cpu_count() or 2
    if not shutil.which("glslangValidator"):
        print("FAIL glslangValidator not found (glslang-tools)")
        return 1
    names = sorted(n for n in os.listdir(glsl) if n.endswith((".frag", ".glsl", ".h")))
    frags = [n for n in names if n.endswith(".frag") and "cm_helpers.glsl" in includes(glsl, n, set())]
    sets = {"Hyprland's": {n: os.path.join(glsl, n) for n in names},
            "OmacVM's": {n: os.path.join(glsl, n) for n in names}}
    sets["OmacVM's"]["cm_helpers.glsl"] = os.path.abspath(ours)
    variants = []
    for frag, version, base in itertools.product(frags, VERSIONS, BASES):
        for bits in itertools.product([0, 1], repeat=len(COLOUR)):
            variants.append((frag, version, base, frozenset(BASES[base] | {c for c, b in zip(COLOUR, bits) if b})))
    print(f"     {len(frags)} fragment shaders with cm_helpers.glsl ({', '.join(frags)}), "
          f"{len(variants)} variants each way")
    fail = 0
    with tempfile.TemporaryDirectory() as work, concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        results = {}
        for label, files in sets.items():
            res = pool.map(build, [(work, files, f, v, feats) for f, v, _, feats in variants])
            results[label] = dict(zip(variants, res))
    theirs, mine = results["Hyprland's"], results["OmacVM's"]
    worse = [v for v in variants if theirs[v][0] and not mine[v][0]]
    better = [v for v in variants if mine[v][0] and not theirs[v][0]]
    ok_theirs = sum(1 for v in variants if theirs[v][0])
    print(f"     compiled: {ok_theirs} with Hyprland's file, {sum(1 for v in variants if mine[v][0])} with OmacVM's")
    for v in worse[:5]:
        print(f"FAIL {v[0]} {v[1]} {v[2]} {sorted(v[3])} compiles with Hyprland's file, not with OmacVM's:")
        print("\n".join(mine[v][1].splitlines()[:6]))
        fail = 1
    if worse:
        print(f"FAIL {len(worse)} variants in all")
    else:
        print("ok   every variant that compiles with Hyprland's cm_helpers.glsl compiles with OmacVM's")
    if better:
        print(f"FAIL {len(better)} variants compile only with OmacVM's file (another file than Hyprland's?)")
        fail = 1
    missing = [(f, ver, sorted(n)) for f in ["surface.frag"] for ver in VERSIONS for n in NEEDED
               if not mine[(f, ver, "window", frozenset(BASES["window"] | n))][0]]
    if missing:
        for m in missing:
            print(f"FAIL a variant captures use does not compile: {m}")
        fail = 1
    else:
        print("ok   the variants a window's capture copy and a window share use compile")
    if ok_theirs < len(variants) // 2:
        print(f"FAIL only {ok_theirs} of {len(variants)} variants compile with Hyprland's own file (a broken run?)")
        fail = 1
    return fail


if __name__ == "__main__":
    sys.exit(main(sys.argv))
