#!/usr/bin/env bash
#
# Release checks for AvatarKitRTC + AvatarKitAgoraBridge.
#
#   scripts/check-release.sh pre  [version]   before `pod trunk push`
#   scripts/check-release.sh post [version]   after both pods are pushed
#   scripts/check-release.sh versions         the version-location section only
#
# A version `<x.y.z>-agora-special.<v>` is an Agora special build
# (release-process.md §9): the podspecs must pin AgoraRtcEngine_Special_iOS <v>,
# and post checks CocoaPods only.
#
# <version> defaults to `spec.version` in AvatarKitRTC/AvatarKitRTC.podspec.
#
# Every check prints one line, `PASS|FAIL|SKIP <check>: <actual value>`, so the
# output can be pasted into the release execution summary as-is. Exit code is
# non-zero when any check fails.
#
# This script is the single authoritative list of where version numbers are
# written down (VERSION_LOCATIONS below). docs/architecture/release-process.md
# points here instead of repeating the list.
#
#   pre   version locations, podspecs parse (`pod ipc spec`), AvatarKitRTC
#         builds for an iOS simulator, CHANGELOG entry (and no leftover
#         [Unreleased]), offline xcframeworks in dist/ if built, the version is not on
#         trunk yet, the tag v<version> exists locally / on origin and carries
#         this version in both podspecs.
#   post  trunk lists the version for both pods, the CocoaPods CDN serves both
#         specs, the tag is on origin, a throwaway SPM package pinned
#         `exact: <version>` resolves (prints what it resolved to) and compiles
#         `import AvatarKitRTC`, and a throwaway app installs the pod from trunk
#         and builds for simulator + device (unsigned). Trunk and
#         the CDN lag behind `pod trunk push`, so those are polled — at most
#         POLL_MINUTES (default 30) in total.
#
# Environment:
#   SIMULATOR_ID=<udid>   simulator for the pre build (default: picked)
#   POLL_MINUTES=<n>      post polling budget (default 30)

set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib/simulator.sh

# Fixed pins that are not "whatever the release says" but deliberate
# constraints — see the Agora comment in Package.swift (4.5.3 builds but
# delivers no frames on a device; 4.6.x changed the callback signature).
PINNED_AGORA="4.5.2"
MIN_IOS="16.0"

PODS=(AvatarKitAgoraBridge AvatarKitRTC)   # trunk push order
SPM_URL="https://github.com/spatius-ai/avatarkit-ios-rtc.git"

mode="${1:-}"
case "$mode" in
    pre|post|versions) ;;
    *)
        echo "usage: $0 pre|post|versions [version]" >&2
        exit 2
        ;;
esac

podspec_version() {
    sed -nE 's/^[[:space:]]*spec\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        AvatarKitRTC/AvatarKitRTC.podspec | head -1
}
version="${2:-$(podspec_version)}"
if [[ -z "$version" ]]; then
    echo "FAIL target-version: cannot read spec.version from AvatarKitRTC/AvatarKitRTC.podspec"
    exit 1
fi

fails=0
pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
skip() { echo "SKIP $1: $2"; }

# Runs python from stdin with the given args; echoes its PASS/FAIL lines and
# adds its FAIL count to the total.
run_section() {
    local out
    out="$(python3 - "$@")" || true
    [[ -n "$out" ]] && echo "$out"
    fails=$((fails + $(grep -c '^FAIL' <<<"$out" || true)))
}

with_retries() {
    # Network calls here flake (TLS resets to github.com); retry a few times.
    local i
    for i in 1 2 3; do
        "$@" && return 0
        sleep 2
    done
    return 1
}

echo "AvatarKitRTC release check — $mode — version $version"
echo

# Agora special build (release-process.md §9): a version
# `<base>-agora-special.<special version>` pins the podspecs to
# AgoraRtcEngine_Special_iOS <special version>. SPM has no special-SDK
# distribution, so Package.swift and the README SPM snippet keep the public
# pin / base version on such a branch, and post skips the SPM checks.
base_version="$version"
special_agora=""
if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-agora-special\.(.+)$ ]]; then
    base_version="${BASH_REMATCH[1]}"
    special_agora="${BASH_REMATCH[2]}"
    echo "Agora special build: podspecs must pin AgoraRtcEngine_Special_iOS $special_agora (base version $base_version)"
    echo
fi
if [[ -n "$special_agora" ]]; then
    podspec_agora_pod="AgoraRtcEngine_Special_iOS"
    podspec_agora_version="$special_agora"
else
    podspec_agora_pod="AgoraRtcEngine_iOS"
    podspec_agora_version="$PINNED_AGORA"
fi

# ---------------------------------------------------------------------------
# Version locations
# ---------------------------------------------------------------------------
check_versions() {
    echo "--- Version locations ---"
    run_section "$version" "$PINNED_AGORA" "$MIN_IOS" "$base_version" "$podspec_agora_pod $podspec_agora_version" <<'PY'
import re, sys
target, agora, min_ios, base, podspec_agora = sys.argv[1:6]

# (group, file, label, regex with one capture group). The group decides what
# the value must equal:
#   rtc       the release version
#   rtc_base  the release version without an -agora-special suffix (SPM side)
#   podagora  "<Agora pod> <version>" the podspecs pin — AgoraRtcEngine_iOS
#             PINNED_AGORA, or AgoraRtcEngine_Special_iOS on a special build
#   main      the main SDK version (reference: Package.swift)
#   protobuf  SwiftProtobuf (reference: Package.swift)
#   agora     PINNED_AGORA, exactly
#   ios       MIN_IOS (Package.swift's `.v16` is normalised to 16.0)
# A regex that no longer matches is a FAIL ("unreadable"), never a silent
# pass — update this table together with whatever moved the line.
VERSION_LOCATIONS = [
    ("rtc", "AvatarKitRTC/AvatarKitRTC.podspec", "spec.version",
     r'^\s*spec\.version\s*=\s*"([^"]+)"'),
    ("rtc", "AvatarKitRTC/AvatarKitAgoraBridge.podspec", "spec.version",
     r'^\s*spec\.version\s*=\s*"([^"]+)"'),
    ("rtc", "AvatarKitRTC/AvatarKitRTC.podspec", "dependency AvatarKitAgoraBridge",
     r'^\s*spec\.dependency\s+"AvatarKitAgoraBridge",\s*"([^"]+)"'),
    ("rtc", "AvatarKitRTC/Sources/AvatarKitRTC/Utils/TelemetryIdentity.swift", "sdkVersion (telemetry sdk_version)",
     r'static let sdkVersion = "([^"]+)"'),
    ("rtc", "Demo/RTCDemo/Integration/TestRunner.swift", "rtcSDKVersion (report header)",
     r'static let rtcSDKVersion = "([^"]+)"'),
    ("rtc_base", "README.md", "SPM install snippet",
     r'avatarkit-ios-rtc\.git",\s*from:\s*"([^"]+)"'),
    ("main", "Package.swift", "avatarkit-ios-release exact",
     r'avatarkit-ios-release\.git",\s*exact:\s*"([^"]+)"'),
    ("main", "AvatarKitRTC/AvatarKitRTC.podspec", "dependency SpatiusAvatarKit",
     r'^\s*spec\.dependency\s+"SpatiusAvatarKit",\s*"([^"]+)"'),
    ("main", "README.md", "Requirements AvatarKit",
     r'^- `AvatarKit` (\S+)'),
    ("protobuf", "Package.swift", "swift-protobuf exact",
     r'swift-protobuf\.git",\s*exact:\s*"([^"]+)"'),
    ("protobuf", "AvatarKitRTC/AvatarKitRTC.podspec", "dependency SwiftProtobuf",
     r'^\s*spec\.dependency\s+"SwiftProtobuf",\s*"([^"]+)"'),
    ("agora", "Package.swift", "AgoraRtcEngine_iOS exact",
     r'AgoraRtcEngine_iOS\.git",\s*exact:\s*"([^"]+)"'),
    ("podagora", "AvatarKitRTC/AvatarKitRTC.podspec", "dependency Agora pod",
     r'^\s*spec\.dependency\s+"(AgoraRtcEngine[A-Za-z_]*)",\s*"([^"]+)"'),
    ("podagora", "AvatarKitRTC/AvatarKitAgoraBridge.podspec", "dependency Agora pod",
     r'^\s*spec\.dependency\s+"(AgoraRtcEngine[A-Za-z_]*)",\s*"([^"]+)"'),
    ("agora", "README.md", "Requirements AgoraRtcEngine_iOS",
     r'^- `AgoraRtcEngine_iOS` (\S+) exactly'),
    ("ios", "Package.swift", "platforms",
     r'platforms:\s*\[\.iOS\(\.v(\d+)\)\]'),
    ("ios", "AvatarKitRTC/AvatarKitRTC.podspec", "spec.platform",
     r'^\s*spec\.platform\s*=\s*:ios,\s*"([^"]+)"'),
    ("ios", "AvatarKitRTC/AvatarKitAgoraBridge.podspec", "spec.platform",
     r'^\s*spec\.platform\s*=\s*:ios,\s*"([^"]+)"'),
    ("ios", "README.md", "Requirements iOS",
     r'^- iOS (\S+)\+'),
]

def read(path, pattern):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(pattern, text, re.M)
    return " ".join(m.groups()) if m else None

values = [(g, f, l, read(f, p)) for g, f, l, p in VERSION_LOCATIONS]

def ref_of(group):
    if group == "rtc":
        return target, "release version"
    if group == "rtc_base":
        return base, "release version without -agora-special suffix"
    if group == "podagora":
        return podspec_agora, "podspec Agora pin"
    if group == "agora":
        return agora, "pinned"
    if group == "ios":
        return min_ios, "minimum iOS"
    first = next(v for g, f, l, v in values if g == group)
    return first, "Package.swift"

for group, path, label, value in values:
    name = f"version.{group} {path} {label}"
    if value is None:
        print(f"FAIL {name}: unreadable — pattern no longer matches; update scripts/check-release.sh")
        continue
    if group == "ios" and "." not in value:
        value += ".0"
    ref, why = ref_of(group)
    if value == ref:
        print(f"PASS {name}: {value}")
    else:
        print(f"FAIL {name}: {value} (expected {ref}, {why})")
PY
    echo
}

check_versions
if [[ "$mode" == "versions" ]]; then
    if [[ $fails -eq 0 ]]; then
        echo "All version checks passed."
        exit 0
    fi
    echo "$fails check(s) failed."
    exit 1
fi

main_version="$(sed -nE 's/.*avatarkit-ios-release\.git",[[:space:]]*exact:[[:space:]]*"([^"]+)".*/\1/p' Package.swift | head -1)"
protobuf_version="$(sed -nE 's/.*swift-protobuf\.git",[[:space:]]*exact:[[:space:]]*"([^"]+)".*/\1/p' Package.swift | head -1)"

# ---------------------------------------------------------------------------
# Tag
# ---------------------------------------------------------------------------
check_tag_local() {
    local tag="v$version" sha head
    if ! sha="$(git rev-parse -q --verify "refs/tags/$tag^{commit}")"; then
        fail "tag $tag local" "missing — tag the release commit before the gate (CocoaPods clones the tag)"
        return
    fi
    head="$(git rev-parse HEAD)"
    if [[ "$sha" == "$head" ]]; then
        pass "tag $tag local" "${sha:0:7} (= HEAD)"
    else
        pass "tag $tag local" "${sha:0:7} (HEAD is ${head:0:7}, not the tag)"
    fi

    # What trunk validates is the podspec at the tag, not the working tree.
    local pod at_tag
    for pod in "${PODS[@]}"; do
        at_tag="$(git show "$tag:AvatarKitRTC/$pod.podspec" 2>/dev/null |
            sed -nE 's/^[[:space:]]*spec\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
        if [[ "$at_tag" == "$version" ]]; then
            pass "tag $tag $pod.podspec" "spec.version $at_tag"
        else
            fail "tag $tag $pod.podspec" "spec.version '${at_tag:-unreadable}' at the tag (expected $version)"
        fi
    done
}

check_tag_remote() {
    local tag="v$version" remote local_sha remote_sha
    if ! remote="$(with_retries git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}" 2>/dev/null)"; then
        fail "tag $tag on origin" "git ls-remote failed (network)"
        return
    fi
    if [[ -z "$remote" ]]; then
        fail "tag $tag on origin" "not pushed — git push origin $tag before pod trunk push"
        return
    fi
    # Annotated tags list a peeled ^{} line with the commit; prefer it.
    remote_sha="$(awk '/\^\{\}$/ {print $1}' <<<"$remote")"
    [[ -z "$remote_sha" ]] && remote_sha="$(awk '{print $1; exit}' <<<"$remote")"
    local_sha="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" || true)"
    if [[ -z "$local_sha" ]]; then
        pass "tag $tag on origin" "${remote_sha:0:7} (no local tag to compare)"
    elif [[ "$local_sha" == "$remote_sha" ]]; then
        pass "tag $tag on origin" "${remote_sha:0:7} (matches local)"
    else
        fail "tag $tag on origin" "${remote_sha:0:7} differs from local ${local_sha:0:7}"
    fi
}

# ---------------------------------------------------------------------------
# Trunk / CDN
# ---------------------------------------------------------------------------

# Prints the comma-separated version list for a pod, "-" when trunk does not
# know the pod (404). Returns 1 when trunk could not be reached.
trunk_versions() {
    local pod="$1" body code
    body="$(mktemp)"
    code="$(curl -s --retry 3 --max-time 30 -o "$body" -w '%{http_code}' \
        "https://trunk.cocoapods.org/api/v1/pods/$pod" || true)"
    case "$code" in
        200) python3 -c 'import json,sys; print(",".join(v["name"] for v in json.load(open(sys.argv[1]))["versions"]))' "$body" ;;
        404) echo "-" ;;
        *) rm -f "$body"; return 1 ;;
    esac
    rm -f "$body"
}

has_version() { tr ',' '\n' <<<"$1" | grep -qxF "$version"; }

# CocoaPods CDN layout: shard = first three hex digits of md5(pod name).
cdn_shard() { local h; h="$(printf %s "$1" | md5)"; echo "${h:0:1}/${h:1:1}/${h:2:1}"; }

# 0 when the CDN index lists the version and the podspec JSON is served with it.
cdn_has_version() {
    local pod="$1" shard index spec
    shard="$(cdn_shard "$pod")"
    index="$(curl -sL --retry 3 --max-time 30 \
        "https://cdn.cocoapods.org/all_pods_versions_${shard//\//_}.txt" | grep "^$pod/" || true)"
    tr '/' '\n' <<<"$index" | tail -n +2 | grep -qxF "$version" || return 1
    spec="$(curl -sL --retry 3 --max-time 30 \
        "https://cdn.cocoapods.org/Specs/$shard/$pod/$version/$pod.podspec.json" || true)"
    python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("version")==sys.argv[2] else 1)' \
        "$spec" "$version" 2>/dev/null
}

# ---------------------------------------------------------------------------
# pre
# ---------------------------------------------------------------------------
if [[ "$mode" == "pre" ]]; then
    echo "--- Podspecs ---"
    if ! command -v pod >/dev/null; then
        fail "podspec parse" "cocoapods not installed"
    else
        for pod in "${PODS[@]}"; do
            err="$(mktemp)"
            json="$(pod ipc spec "AvatarKitRTC/$pod.podspec" 2>"$err")" || {
                fail "podspec $pod (pod ipc spec)" "does not parse: $(head -3 "$err" | tr '\n' ' ')"
                rm -f "$err"
                continue
            }
            rm -f "$err"
            run_section "$pod" "$version" "$main_version" "$protobuf_version" "$podspec_agora_version" "$MIN_IOS" "$json" "$podspec_agora_pod" <<'PY'
import json, sys
pod, version, main, protobuf, agora, min_ios, raw, agora_pod = sys.argv[1:9]
spec = json.loads(raw)
expected_deps = {agora_pod: [agora]}
if pod == "AvatarKitRTC":
    expected_deps.update({
        "AvatarKitAgoraBridge": [version],
        "SpatiusAvatarKit": [main],
        "SwiftProtobuf": [protobuf],
    })
problems = []
if spec.get("version") != version:
    problems.append(f"version {spec.get('version')} != {version}")
if spec.get("source", {}).get("tag") != f"v{version}":
    problems.append(f"source tag {spec.get('source', {}).get('tag')} != v{version}")
if spec.get("platforms", {}).get("ios") != min_ios:
    problems.append(f"platform ios {spec.get('platforms', {}).get('ios')} != {min_ios}")
deps = spec.get("dependencies", {})
if deps != expected_deps:
    problems.append(f"dependencies {deps} != {expected_deps}")
summary = (f"version {spec.get('version')}, tag {spec.get('source', {}).get('tag')}, deps "
           + ", ".join(f"{k} {'/'.join(v)}" for k, v in deps.items()))
name = f"podspec {pod} (pod ipc spec)"
print(f"FAIL {name}: " + "; ".join(problems) if problems else f"PASS {name}: {summary}")
PY
        done
    fi
    echo

    echo "--- Build ---"
    if ! picked="$(pick_simulator)"; then
        fail "build AvatarKitRTC" "no available iPhone simulator"
    else
        sim_id="${picked%% *}"
        sim_desc="${picked#* }"
        tmp_root="${TMPDIR:-/tmp}"
        derived="$(mktemp -d "${tmp_root%/}/avatarkit-rtc-release.XXXXXX")"
        if xcodebuild build -scheme AvatarKitRTC \
                -destination "platform=iOS Simulator,id=$sim_id" \
                -derivedDataPath "$derived" >"$derived/build.log" 2>&1; then
            pass "build AvatarKitRTC (xcodebuild, iOS Simulator)" "BUILD SUCCEEDED on $sim_desc"
            rm -rf "$derived"
        else
            grep -E "error:" "$derived/build.log" | head -10 || true
            fail "build AvatarKitRTC (xcodebuild, iOS Simulator)" "BUILD FAILED on $sim_desc (log: $derived/build.log)"
        fi
    fi
    echo

    echo "--- CHANGELOG ---"
    if grep -qE "^## \[$(sed 's/[.]/\\./g' <<<"$version")\]" CHANGELOG.md; then
        pass "CHANGELOG" "$(grep -E "^## \[$(sed 's/[.]/\\./g' <<<"$version")\]" CHANGELOG.md | head -1)"
    else
        fail "CHANGELOG" "no '## [$version]' entry in CHANGELOG.md"
    fi
    # An [Unreleased] section left in place means the rename to the version was
    # forgotten, or something landed after the entry was written.
    if grep -qE '^## \[Unreleased\]' CHANGELOG.md; then
        fail "CHANGELOG no [Unreleased] section" "'## [Unreleased]' still present — rename it to the version or move its items"
    else
        pass "CHANGELOG no [Unreleased] section" "absent"
    fi
    echo

    echo "--- Not yet published ---"
    for pod in "${PODS[@]}"; do
        if ! versions="$(trunk_versions "$pod")"; then
            fail "trunk $pod $version not published" "trunk API unreachable"
        elif [[ "$versions" == "-" ]]; then
            pass "trunk $pod $version not published" "pod not registered on trunk"
        elif has_version "$versions"; then
            fail "trunk $pod $version not published" "$version is already on trunk (published: $versions)"
        else
            pass "trunk $pod $version not published" "published: $versions"
        fi
    done
    echo

    echo "--- Tag ---"
    check_tag_local
    check_tag_remote
    echo

    # Offline delivery (release-process §6.2). Only checked when
    # build-xcframework.sh has produced dist/ — most releases don't ship it.
    echo "--- Offline xcframeworks (dist/) ---"
    for module in "${PODS[@]}"; do
        xcf="dist/$module.xcframework"
        if [[ ! -d "$xcf" ]]; then
            skip "xcframework $module" "$xcf not built (only needed for offline delivery, §6.2)"
            continue
        fi
        # CFBundleShortVersionString is numeric-only, so a framework carries the
        # base version (an -agora-special suffix is dropped by CocoaPods); the
        # full version is checked on the zip and DEPENDENCIES.txt below.
        run_section "$module" "$base_version" "$xcf" <<'PY'
import json, subprocess, sys, pathlib
module, version, xcf = sys.argv[1:4]
def plist(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
libs = plist(pathlib.Path(xcf) / "Info.plist").get("AvailableLibraries", [])
slices = sorted((l.get("SupportedPlatform"), l.get("SupportedPlatformVariant", "device"),
                 ",".join(sorted(l.get("SupportedArchitectures", [])))) for l in libs)
want = [("ios", "device", "arm64"), ("ios", "simulator", "arm64")]
desc = "; ".join(f"{p}-{v} [{a}]" for p, v, a in slices)
print(("PASS" if slices == want else "FAIL") + f" xcframework {module} slices: {desc}"
      + ("" if slices == want else " (expected ios-device [arm64]; ios-simulator [arm64])"))
for lib in libs:
    info = pathlib.Path(xcf) / lib["LibraryIdentifier"] / lib["LibraryPath"] / "Info.plist"
    got = plist(info).get("CFBundleShortVersionString") if info.exists() else None
    ok = got == version
    print(("PASS" if ok else "FAIL") + f" xcframework {module} {lib['LibraryIdentifier']} version: {got}"
          + ("" if ok else f" (expected {version} — stale dist/? rebuild)"))
PY
    done
    if [[ -d dist/AvatarKitRTC.xcframework ]]; then
        zip_path="dist/AvatarKitRTC-$version-xcframeworks.zip"
        if [[ -f "$zip_path" ]]; then
            pass "xcframework zip" "$zip_path ($(du -h "$zip_path" | cut -f1 | tr -d ' '))"
        else
            fail "xcframework zip" "$zip_path missing — rerun ./build-xcframework.sh"
        fi
        deps_head="$(head -1 dist/DEPENDENCIES.txt 2>/dev/null || true)"
        deps_agora="$(grep -E '^  - Agora: ' dist/DEPENDENCIES.txt 2>/dev/null | sed 's/^  - Agora: //; s/ —.*//' || true)"
        if [[ "$deps_head" == "AvatarKitRTC $version "* && "$deps_agora" == "$podspec_agora_pod $podspec_agora_version" ]]; then
            pass "xcframework DEPENDENCIES.txt" "$version; Agora $deps_agora"
        else
            fail "xcframework DEPENDENCIES.txt" "'${deps_head:-missing}' / Agora '${deps_agora:-?}' (expected $version / $podspec_agora_pod $podspec_agora_version — stale dist/?)"
        fi
    fi
    echo
fi

# ---------------------------------------------------------------------------
# post
# ---------------------------------------------------------------------------
if [[ "$mode" == "post" ]]; then
    poll_minutes="${POLL_MINUTES:-30}"
    started=$SECONDS
    deadline=$((SECONDS + poll_minutes * 60))

    # poll <description> <command...>: retries every 30 s until the command
    # succeeds or the shared deadline passes. Sets `waited` to the time spent
    # waiting (0 when the first attempt succeeded).
    poll() {
        local what="$1"; shift
        local t0=$SECONDS
        waited=0
        while ! "$@"; do
            waited=$((SECONDS - t0))
            if (( SECONDS >= deadline )); then
                echo "  ... gave up on $what after ${waited}s (POLL_MINUTES=$poll_minutes)"
                return 1
            fi
            echo "  ... waiting for $what (${waited}s)"
            sleep 30
        done
        (( waited > 0 )) && waited=$((SECONDS - t0))
        return 0
    }

    # Leaves the last list it saw in `trunk_seen` for the report line.
    trunk_seen=""
    trunk_lists() { trunk_seen="$(trunk_versions "$1")" || { trunk_seen="unreachable"; return 1; }; has_version "$trunk_seen"; }

    echo "--- Trunk ---"
    for pod in "${PODS[@]}"; do
        if poll "trunk $pod $version" trunk_lists "$pod"; then
            pass "trunk $pod $version" "listed (versions: $trunk_seen; waited ${waited}s)"
        else
            fail "trunk $pod $version" "not listed by trunk API (versions: $trunk_seen)"
        fi
    done
    echo

    echo "--- CDN ---"
    for pod in "${PODS[@]}"; do
        url="https://cdn.cocoapods.org/Specs/$(cdn_shard "$pod")/$pod/$version/$pod.podspec.json"
        if poll "CDN $pod $version" cdn_has_version "$pod"; then
            pass "cdn $pod $version" "in all_pods_versions_$(cdn_shard "$pod" | tr / _).txt, $url served (waited ${waited}s)"
        else
            fail "cdn $pod $version" "not on the CDN yet ($url)"
        fi
    done
    echo

    echo "--- Tag ---"
    check_tag_remote
    echo

    echo "--- SPM resolve ---"
    if [[ -n "$special_agora" ]]; then
        skip "spm resolve / consumer build" "Agora special build — SPM has no special-SDK distribution; CocoaPods only"
    else
    # Expected pins are the ones in Package.swift at the tag (what SPM sees).
    tag_pkg="$(git show "v$version:Package.swift" 2>/dev/null || cat Package.swift)"
    expected_main="$(sed -nE 's/.*avatarkit-ios-release\.git",[[:space:]]*exact:[[:space:]]*"([^"]+)".*/\1/p' <<<"$tag_pkg" | head -1)"
    tmp_root="${TMPDIR:-/tmp}"
    spm_dir="$(mktemp -d "${tmp_root%/}/avatarkit-rtc-spm.XXXXXX")"
    mkdir -p "$spm_dir/Sources/Probe"
    cat >"$spm_dir/Sources/Probe/Probe.swift" <<'SWIFT'
import AvatarKitRTC

// Compile-time touch of the public API; never run.
enum Probe {
    static let player: Any.Type = AvatarPlayer.self
}
SWIFT
    cat >"$spm_dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.iOS(.v16)],
    // An explicit library product is what gives Xcode a "Probe" scheme to build.
    products: [.library(name: "Probe", targets: ["Probe"])],
    dependencies: [
        .package(url: "$SPM_URL", exact: "$version"),
    ],
    targets: [
        .target(name: "Probe", dependencies: [
            .product(name: "AvatarKitRTC", package: "avatarkit-ios-rtc"),
        ]),
    ]
)
EOF
    # The first resolve on a machine downloads the binary artifacts (AvatarKit,
    # Agora) and can take many minutes; later runs hit SwiftPM's cache.
    spm_t0=$SECONDS
    if (cd "$spm_dir" && with_retries swift package resolve >"$spm_dir/resolve.log" 2>&1); then
        echo "  (swift package resolve took $((SECONDS - spm_t0))s)"
        run_section "$spm_dir/Package.resolved" "$version" "$expected_main" "$PINNED_AGORA" <<'PY'
import json, sys
path, version, main, agora = sys.argv[1:5]
pins = {p["identity"]: p["state"].get("version") for p in json.load(open(path))["pins"]}
for identity, want in (("avatarkit-ios-rtc", version),
                       ("avatarkit-ios-release", main),
                       ("agorartcengine_ios", agora)):
    got = pins.get(identity)
    status = "PASS" if got == want else "FAIL"
    suffix = "" if got == want else f" (expected {want})"
    print(f"{status} spm resolve {identity}: {got}{suffix}")
PY
        if picked="$(pick_simulator)"; then
            if (cd "$spm_dir" && xcodebuild build -scheme Probe \
                    -destination "platform=iOS Simulator,id=${picked%% *}" \
                    -derivedDataPath "$spm_dir/dd" >"$spm_dir/build.log" 2>&1); then
                pass "spm consumer build (import AvatarKitRTC, iOS Simulator)" "BUILD SUCCEEDED on ${picked#* }"
                rm -rf "$spm_dir"
            else
                grep -E "error:" "$spm_dir/build.log" | head -5 || true
                fail "spm consumer build (import AvatarKitRTC, iOS Simulator)" "BUILD FAILED (log: $spm_dir/build.log)"
            fi
        else
            fail "spm consumer build" "no available iPhone simulator"
        fi
    else
        tail -5 "$spm_dir/resolve.log"
        fail "spm resolve" "swift package resolve failed (log: $spm_dir/resolve.log)"
    fi
    fi
    echo

    echo "--- CocoaPods consumer ---"
    # A throwaway app that installs AvatarKitRTC from trunk exactly as a host
    # would (static frameworks), then builds for the simulator and for a device
    # (unsigned). Catches what the trunk/CDN checks cannot: resolution across
    # the two pods + SpatiusAvatarKit + Agora, and compile/link errors.
    if ! command -v xcodegen >/dev/null || ! command -v pod >/dev/null; then
        fail "cocoapods consumer" "needs xcodegen and cocoapods"
    else
        pod_dir="$(mktemp -d "${tmp_root%/}/avatarkit-rtc-pod.XXXXXX")"
        mkdir -p "$pod_dir/App"
        cat >"$pod_dir/App/App.swift" <<'SWIFT'
import SwiftUI
import AvatarKitRTC

@main
struct ConsumerApp: App {
    // Compile-time touch of the public API.
    let player: Any.Type = AvatarPlayer.self
    var body: some Scene { WindowGroup { Text("rtc consumer") } }
}
SWIFT
        cat >"$pod_dir/project.yml" <<'YML'
name: RTCPodConsumer
options:
  bundleIdPrefix: check.rtc
  deploymentTarget:
    iOS: "16.0"
targets:
  RTCPodConsumer:
    type: application
    platform: iOS
    sources: [App]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: check.rtc.consumer
YML
        cat >"$pod_dir/Podfile" <<PODFILE
platform :ios, '16.0'
target 'RTCPodConsumer' do
  use_frameworks! :linkage => :static
  pod 'AvatarKitRTC', '$version'
end
PODFILE
        if (cd "$pod_dir" && xcodegen generate >/dev/null 2>&1 \
                && with_retries pod install --repo-update >"$pod_dir/pod.log" 2>&1); then
            installed="$(grep -E '^Installing ' "$pod_dir/pod.log" | sed 's/^Installing //' | paste -sd, - | sed 's/,/, /g')"
            pass "cocoapods consumer pod install" "$installed"
            consumer_ok=1
            for dest in "iOS Simulator" "iOS"; do
                log="$pod_dir/build-${dest// /-}.log"
                if (cd "$pod_dir" && xcodebuild build -workspace RTCPodConsumer.xcworkspace \
                        -scheme RTCPodConsumer -destination "generic/platform=$dest" \
                        -derivedDataPath "$pod_dir/dd" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
                        >"$log" 2>&1); then
                    pass "cocoapods consumer build ($dest)" "BUILD SUCCEEDED"
                else
                    consumer_ok=0
                    grep -E "error:" "$log" | head -5 || true
                    fail "cocoapods consumer build ($dest)" "BUILD FAILED (log: $log)"
                fi
            done
            (( consumer_ok )) && rm -rf "$pod_dir"
        else
            tail -5 "$pod_dir/pod.log" 2>/dev/null || true
            fail "cocoapods consumer pod install" "failed (log: $pod_dir/pod.log)"
        fi
    fi
    echo
    echo "Post-release checks took $((SECONDS - started))s."
fi

if [[ $fails -eq 0 ]]; then
    echo "All checks passed."
else
    echo "$fails check(s) failed."
    exit 1
fi
