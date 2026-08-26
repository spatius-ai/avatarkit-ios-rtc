---
id: ADR-0001
applies_to: ["AvatarKitRTC/Sources/AvatarKitRTC/Utils/TelemetryIdentity.swift", "AvatarKitRTC/*.podspec", "scripts/check_version_consistency.sh"]
status: accepted
date: 2026-08-26
deciders: Wangruizhen
---

# 0001. Keep the telemetry version hand-written, verify it with a script

## Context

`TelemetryIdentity.sdkVersion` is the `sdk_version` injected into the OTel Resource,
and every record this SDK reports carries it. It is a hand-written constant, and it
has already drifted twice:

- it sat at `beta.6` for the whole beta.7 release cycle (only fixed in `dc3aee9`)
- `52f258d release: v1.0.0` updated the two podspecs but missed this file, so
 **every record reported by v1.0.0 carried `1.0.0-beta.9`, a version that was never
 released**

Drift produces no build error and behaves perfectly at runtime — the wrong version
just quietly shows up in the data. Both times it was the same convention failing:
"check each spot by hand at release time."

The other two platforms do not have this problem: web injects
`__RTC_SDK_VERSION__` from `package.json` via vite `define`, and Android generates
`BuildConfig.SDK_VERSION` from `gradle.properties` via `buildConfigField` — both
resolved automatically at build time.

## Decision

The version stays hand-written; no automatic injection. Add
`scripts/check_version_consistency.sh`, which compares the constant against the two
podspecs and exits 1 on any mismatch; wire it into the pre-release checklist and the
step before tagging.

## Alternatives considered

**Build-time injection (aligned with web / Android)** — verified to be impossible on
SPM. Swift Package Manager has no equivalent of vite `define` or Gradle's
`buildConfigField`: a package cannot read its own podspec, cannot read the git tag,
and has no hook for generating a source constant. The iOS host SDK is under the same
constraint and is likewise hand-written (`AvatarSDK.swift:489`,
`nonisolated public static var version: String { "1.3.3" }`). This is not laziness at
this layer — the platform simply does not offer the path.

**`sed` the source in the release script** — have `build-xcframework.sh` write the
version into `TelemetryIdentity.swift` at release time. Some libraries in the
CocoaPods ecosystem do this. **Not adopted, and not tried**: the source still holds a
literal, only overwritten at release, so the hand-writing is not actually eliminated,
while it introduces a new source of confusion — the source in the repo no longer
matches the artifact. If the check script later proves insufficient, this is the next
option to evaluate.

**Status quo (keep checking by hand)** — it has already failed twice, in exactly the
same way.

## Consequences

- The release process can catch drift before tagging instead of relying on someone
  remembering
- Cost: one more release step; the constant itself is still maintained by hand, and
 the script only guarantees the three spots are **consistent with each other**, not
 that they are **collectively correct** (if all three are given the same wrong
 version, the script cannot tell)
- The script covers 3 of the 5 places a version lives; cross-references inside the
  podspecs and the git tag still need a manual check
- **The published v1.0.0 artifacts cannot be corrected retroactively**; the
 `sdk_version` for that batch of data will always be `1.0.0-beta.9`, and anyone
 analyzing v1.0.0 telemetry has to know this
- The script itself is a new point of dependency: if the shape of the version line
 ever changes (say a podspec is reformatted), the script fails with "UNREADABLE"
 rather than silently passing — deliberately so; better noisy than missed
