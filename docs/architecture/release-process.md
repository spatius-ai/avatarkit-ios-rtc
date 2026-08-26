# Release Process — iOS RTC SDK

Layer: **current state** — rewritten in place whenever the build or publish flow
changes. Verified against build config on every release
(→ `knowledge/workflows/release-workflow.md` §1.1).

> For the general release process (checklist, gate rules, report schema, cross-SDK
> alignment, API deprecation policy) see
> [`sdk-release-manager/README.md`](../../../sdk-release-manager/README.md).
> This document covers only the steps specific to iOS RTC.

## 1. Scope

| | |
|---|---|
| Repository | `avatarkit-ios-rtc` (`spatius-ai/avatarkit-ios-rtc`) |
| Pods | **`AvatarKitRTC`** + **`AvatarKitAgoraBridge`** — both must be published |
| SPM product | `AvatarKitRTC` (the bridge is not exposed as a product, `Package.swift:8-13`) |
| Distribution channels | **Three**: CocoaPods trunk, SPM (via git tag), offline xcframework zip |
| CI | **None.** The repo has no `.github/`; every gate is run manually and locally |
| Platform | iOS 16.0, Swift 6.0 |

## 2. Version numbers — 5 places, 3 of them checked by a script

| # | Location | Current value | Nature |
|---|------|--------|------|
| 1 | `AvatarKitRTC/AvatarKitRTC.podspec:3` | `1.0.0` | pod version |
| 2 | `AvatarKitRTC/AvatarKitAgoraBridge.podspec:3` | `1.0.0` | pod version, **must stay in sync with #1** |
| 3 | `AvatarKitRTC.podspec:44` | `spec.dependency "AvatarKitAgoraBridge", "1.0.0"` | **Cross-reference — must be bumped too** |
| 4 | `Sources/AvatarKitRTC/Utils/TelemetryIdentity.swift` | `1.0.0` | Hand-written constant, injected into telemetry as `sdk_version` |
| 5 | git tag `v<version>` | `v1.0.0` | Both podspecs rely on it via `:tag => "v#{spec.version}"` |

`Package.swift` itself **contains no version number** — the SPM version is
determined entirely by the git tag. This is a structural difference from Android,
which records the version in `gradle.properties`.

> **Why #4 is hand-written.**
>
> Swift Package Manager has no build-time substitution mechanism: a package
> cannot read its own podspec or git tag, and it cannot generate constants.
> Compare with web (vite `define` injects `__RTC_SDK_VERSION__` from
> package.json) and Android (`BuildConfig.SDK_VERSION` ←
> `gradle.properties`) — **iOS is the only platform with no automatic source**,
> so this constant *is* the source of truth.
>
> Forgetting to bump it produces no build error at all — every telemetry record
> just carries a version that was never released, while production behaves
> perfectly normally. **It has already drifted twice**: it sat at beta.6 for the
> entire beta.7 cycle (fixed in `dc3aee9`), and it sat at beta.9 after the 1.0.0
> release (corrected this round). Both times "check it by hand each release"
> failed, so a script is now the backstop:

```bash
./scripts/check_version_consistency.sh
```

> It compares #1 / #2 / #4 and exits 1 on any mismatch. **It must pass before
> tagging a release** (see the "Release steps" section). #3 and #5 are outside
> the script's reach and still need a manual check.

### Host SDK dependency — a hard constraint, the opposite trade-off from Android

| Distribution | Declaration | Location |
|------|------|------|
| SPM | `.package(url: …avatarkit-ios-release, exact: "1.3.3")` | `Package.swift:17` |
| CocoaPods | `spec.dependency "SpatiusAvatarKit", "1.3.3"` | `AvatarKitRTC.podspec:47` |

Both pin an **exact version**; the comment at `Package.swift:15-16` explains why:
it keeps SPM and the podspec locked to the same host SDK version. Third-party
dependencies are pinned exactly as well: SwiftProtobuf 1.30.0, AgoraRtcEngine_iOS 4.5.2.

> **Contrast with Android — each side pays a different price:**
>
> Android uses `compileOnly`, which **never reaches the POM and imposes no
> constraint at all** — nothing checks the host app's version, and a wrong one
> only surfaces as a `NoSuchMethodError` when a missing API is called. The
> version requirement can only be stated in README prose.
>
> The iOS `exact:` is a **real constraint the resolver enforces**: a wrong
> version fails during dependency resolution. The price is that **if the host App
> also depends on AvatarKit at any version other than 1.3.3, SPM fails to
> resolve outright — there is no room to negotiate**. Whenever the host SDK is
> bumped, this repo must ship a matching release, or host apps cannot upgrade.
>
> These are symmetric trade-offs, not a right and a wrong answer.

## 3. Pre-release Checklist

1. Confirm the release branch is correct and carries no unrelated changes
2. After updating all 5 version numbers from §2, run `./scripts/check_version_consistency.sh`
   — it covers #1 / #2 / #4; **#3 (the cross-reference inside the podspec) and #5 (the git tag) still need a manual check**
3. Confirm `CHANGELOG.md` is filled in (including the host SDK version this release depends on)
4. Confirm the target version is not already taken on trunk
5. If the host SDK was bumped, confirm `Package.swift:17` and `AvatarKitRTC.podspec:47` are in sync

## 4. Local verification

```bash
swift build                                   # SPM build
xcodebuild test -scheme AvatarKitRTC ...       # runs only 1 smoke unit test
```

> `xcodebuild test` covers only the single smoke case in `AvatarKitRTCTests`;
> **it does not reach the 63 integration cases** (see
> [`test-cases.md`](test-cases.md) §1).

**Manual verification on a device** (inside the demo app):

- **MOCK (43 cases)** — no Agora link, deterministic; should be run on every release
- **LIVE (20 cases)** — requires a real Agora channel and a backend token

Note that MOCK mode **still requires** a valid appID / avatarID and network
access (the avatar is genuinely loaded); it simply does not connect to Agora.
See [`test-cases.md`](test-cases.md) §2 for the full prerequisites.

**CocoaPods integration check (strongly recommended)**: create a **clean
project**, install the **actually published** pod from trunk, and **build it on
both the simulator and a real device**. The simulator architecture bug in
`4e6c188` (see §7) was caught exactly this way — `pod lib lint` does not catch it.

## 5. Documentation alignment gate (mandatory before release, hard gate)

**`docs/architecture/` asserts "how the code works today". Before every release,
each file must be re-verified against the code actually being shipped** — this is
a hard gate; shipping with a stale current-state layer is not allowed.

Rules and the per-item checklist → `knowledge/workflows/release-workflow.md` §1.1

| File | Verified against | Gate question |
|------|---------|---------|
| [`overview.md`](overview.md) | `Sources/AvatarKitRTC/` | Do the module split, the provider abstraction, the jitter constants and the two lifecycle paths still hold? |
| [`telemetry-fields.md`](telemetry-fields.md) | `Utils/Telemetry.swift` and its call sites | Is the metric / event list complete? Have the known gaps in §5 changed? `TelemetryIdentity.sdkVersion` is guaranteed by `check_version_consistency.sh` |
| [`test-cases.md`](test-cases.md) | `Demo/RTCDemo/Integration/` | Are mock 43 / live 20 still correct? Has the id mapping against Android changed? |
| [`release-process.md`](release-process.md) (this file) | podspec / Package.swift / scripts | Are the version list, the commands and the dependency versions still accurate? |
| [`docs-map.md`](docs-map.md) | the `docs/` file listing | Were any docs added or removed without being registered? |

Requirements:

- Verifying means **reading the code**, not going from memory.
- Any drift found is **fixed in the release commit itself**, never deferred.
- If a file cannot be brought up to date in time, postpone the release or revert the change.
- `docs/iterations/` is **not** part of this gate.

## 6. Release steps

```bash
# 1. Update the 5 version numbers from §2 (including TelemetryIdentity.swift)
./scripts/check_version_consistency.sh         # must pass, otherwise telemetry ships the wrong version
# 2. Update CHANGELOG.md
# 3. Local verification (§4) + documentation alignment gate (§5)
# 4. commit + tag
git commit -m "release: v<version>"
git tag v<version>
git push origin main && git push origin v<version>

# 5. Manual gate — stop here and wait for the release owner's confirmation

# 6. Publish to CocoaPods — the order matters
cd AvatarKitRTC
pod trunk push AvatarKitAgoraBridge.podspec    # bridge first
pod trunk push AvatarKitRTC.podspec            # then the main pod
```

> 🚦 **Manual gate**: `pod trunk push` is an **irreversible public release**, on
> the same level as npm publish / Maven Central / pub publish. Once a version is
> out, it is taken forever. It must only be run after the release owner has
> explicitly confirmed.

> ⚠️ **The publish order cannot be reversed**: `AvatarKitRTC` depends on an
> **exact version** of `AvatarKitAgoraBridge` (`podspec:44`). Publishing the main
> pod first fails because the dependency cannot be resolved. Both pods share the
> same git tag, so their versions must be bumped together.

> **The tag must be pushed first**: the source of both podspecs is
> `:tag => "v#{spec.version}"`, and trunk clones that tag. If the tag is not on
> the remote, the push fails immediately.

### Offline xcframework delivery (the third channel)

`build-xcframework.sh` (repo root, 124 lines) produces distributable
`AvatarKitRTC.xcframework` + `AvatarKitAgoraBridge.xcframework`:

```bash
AVATARKIT_POD_PATH=/path/to/local/avatarkit \
AGORA_VERSION=4.5.2 \
./build-xcframework.sh
```

It requires `cocoapods` + `xcodegen` plus a local copy of the AvatarKit pod
(`:33-40` validates this and exits outright if it is missing). Output lands in
`dist/` (gitignored), each containing a device and a simulator arm64 slice. Both
frameworks are **static**; third-party dependencies are not embedded and are used
only for symbol resolution (`:10-12`).

> **One hidden coupling**: at `:51-54` the script `sed`s `"AvatarKitRTC/Sources/`
> in the podspec into `"Sources/` (a remote checkout carries the subdirectory
> prefix, a local `:path` reference does not). **Changing the `source_files` path
> prefix in the podspec will break this script at the same time.**

The end of the script (`:123-124`) points out that the host SDK's
`AvatarKit.xcframework` is taken verbatim from the ios-release GitHub Release and
must be packaged into the delivery zip alongside these two.

## 7. Simulator architecture exclusion (`4e6c188`)

`AvatarKitRTC.podspec:26-39` declares
`EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` **twice**: once in
`pod_target_xcconfig` and once in `user_target_xcconfig`.

**Why both are needed**: the host SDK's simulator slice is arm64-only, and **a
dependency pod's xcconfig does not propagate to the dependent pod's target**.
Without the local copy, the `AvatarKitRTC` target still builds for x86_64, the
whole AvatarKit module fails to resolve, and every public type reports "cannot
find in scope".

The only thing excluded is the Intel Mac simulator — which the host SDK never
supported anyway (both the Metal renderer and the core binary ship arm64 only).
Apple Silicon is unaffected.

> ⚠️ **`AvatarKitAgoraBridge.podspec` has no such exclusion** (it only carries the
> C++17 settings, `:25-28`). It does not break today only because it depends on
> Agora alone (which has an x86_64 slice) and never touches the host SDK. **The
> moment the bridge pulls in any host SDK symbol, the same bug reappears.**

> **`pod lib lint` cannot catch this class of problem** — only the clean-project
> verification from §4 can.

## 8. Post-release

1. Confirm both pods are visible on trunk: `pod trunk info AvatarKitRTC` / `AvatarKitAgoraBridge`
2. Smoke install in a clean project, **built separately for simulator and device**
3. Confirm that on the SPM side `.package(url:…, from: "<version>")` resolves to the new tag
4. **Public docs**: this repo has no standalone public documentation — `README.md`
   points at the web rtc-adapter docs. When the API changes, assess whether that
 shared document needs updating
5. Append an entry for this release to [`../iterations/`](../iterations/), stating which
   `architecture/` files were re-verified per §5 and what drift was fixed
   (→ `knowledge/workflows/commit-workflow.md`)

## Related

- Docs index → [`../README.md`](../README.md)
- Docs map → [`docs-map.md`](docs-map.md)
- Architecture → [`overview.md`](overview.md)
- Telemetry → [`telemetry-fields.md`](telemetry-fields.md)
- Tests → [`test-cases.md`](test-cases.md)
