# Release Process — iOS RTC SDK

Layer: **current state** — rewritten in place whenever the build or publish flow
changes. Verified against the build config on every release (§5).

This document is the complete release procedure for this repo; nothing else has
to be read to ship. Web and Android RTC use the same section structure and the
same MOCK case catalog ([`test-cases.md`](test-cases.md) §2).

## 1. Scope

| | |
|---|---|
| Repository | `avatarkit-ios-rtc` (`spatius-ai/avatarkit-ios-rtc`) |
| Pods | **`AvatarKitAgoraBridge`** + **`AvatarKitRTC`** — both are published, in that order (§6) |
| SPM product | `AvatarKitRTC` (the bridge is not exposed as a product, `Package.swift:8-13`) |
| Distribution channels | **Three**: CocoaPods via our spec repo [`spatius-ai/avatarkit-specs`](https://github.com/spatius-ai/avatarkit-specs) (shared with `SpatiusAvatarKit`; CocoaPods trunk is read-only from 2026-12-02), SPM (via the git tag), offline xcframework zip (§6.2) |
| CI | **None.** The repo has no `.github/`; every gate is run manually and locally |
| Platform | iOS 16.0, Swift 6.0, arm64 (device and Apple Silicon simulator) |
| Toolchain | Xcode (tested with 26.x), CocoaPods (`pod`), `python3`, `curl`; `xcodegen` only for the xcframework |

## 2. Version numbers and dependencies

**`scripts/check-release.sh` is the single authoritative list of version
locations** (`VERSION_LOCATIONS` in the script). This document does not repeat
the list or the current values; run the script to see both:

```bash
scripts/check-release.sh versions     # just the version section
```

It covers, and requires to agree:

- **This package's version** — both podspecs' `spec.version`, `AvatarKitRTC.podspec`'s
  dependency on `AvatarKitAgoraBridge`, `TelemetryIdentity.sdkVersion`, the demo's
  report-header mirror `TestRunner.rtcSDKVersion`, and the README install snippet.
- **The main SDK version** — `Package.swift` (`avatarkit-ios-release`, `exact:`),
  the podspec's `SpatiusAvatarKit` dependency, and README Requirements.
- **Fixed pins** — Agora exactly `4.5.2` (Package.swift, both podspecs, README),
  SwiftProtobuf (Package.swift = podspec), minimum iOS 16.0 (Package.swift, both
  podspecs, README). On an Agora special-build branch (§9) the podspecs pin
  `AgoraRtcEngine_Special_iOS` instead; the script derives that from the version.

`scripts/check_version_consistency.sh` (named in ADR-0001) now just runs that
section.

`Package.swift` itself carries no version of this package — the SPM version is
the git tag `v<version>`, which both podspecs also use as their source
(`:tag => "v#{spec.version}"`).

### Why the telemetry version is hand-written

Swift Package Manager has no build-time substitution: a package cannot read its
own podspec or git tag, and cannot generate constants. Web injects
`__RTC_SDK_VERSION__` from package.json and Android generates
`BuildConfig.SDK_VERSION`; on iOS the constant *is* the source of truth. A
forgotten bump produces no build error — every telemetry record just carries a
version that was never released. It drifted twice (beta.6 through the beta.7
cycle, fixed in `dc3aee9`; beta.9 after the 1.0.0 release, corrected in 1.0.1),
which is why the script exists → [ADR-0001](../decisions/0001-telemetry-version-hand-written.md).
The demo's `rtcSDKVersion` is a second hand-written copy for the same reason (the
library constant is internal); the script covers it too.

### Main SDK dependency — exact on both channels

| Channel | Declaration |
|---|---|
| SPM | `.package(url: …avatarkit-ios-release.git, exact: "<main>")` (`Package.swift:15-17`) |
| CocoaPods | `spec.dependency "SpatiusAvatarKit", "<main>"` (`AvatarKitRTC.podspec:48-51`) |

The main SDK is published to CocoaPods as `SpatiusAvatarKit` (`AvatarKit` was
taken); its module name is still `AvatarKit`.

Unlike Android's `compileOnly` (never reaches the POM, nothing checks the host's
version), the iOS `exact:` is enforced by the resolver: a wrong version fails at
resolution time. The price: **a host app that depends on AvatarKit at any other
version cannot resolve at all**, so every main-SDK bump needs a matching RTC
release.

### Agora pinned exactly to 4.5.2

Not `4.5.x`: with 4.5.3 the bridge compiles and the encoded-frame headers are
unchanged, yet on a device the observer receives no frames after a successful
join; 4.6.x changed the callback signature (`Package.swift:19-24`). Moving the pin
requires a device re-test, never just a green build.

### Two pods, one version

`AvatarKitRTC` depends on an **exact** `AvatarKitAgoraBridge` version
(`AvatarKitRTC.podspec:44-47`). The bridge is a separate pod rather than a subspec
so that it compiles as its own Clang module (`import AvatarKitAgoraBridge`),
matching the SPM target layout. Both share the tag, so both versions move together
and the bridge is pushed first (§6).

## 3. Pre-release Checklist

1. Release branch is correct and carries no unrelated changes.
2. All version locations bumped; `scripts/check-release.sh versions` passes.
3. `CHANGELOG.md` has a `## [<version>]` entry, including the main SDK version
   this release requires.
4. If the main SDK was bumped: that `SpatiusAvatarKit` version is already in
   `avatarkit-specs` and the `avatarkit-ios-release` tag exists.
5. The target version is not in `avatarkit-specs` yet (checked by `check-release.sh pre`).
6. `pod repo list` shows `avatarkit-specs` (one-time setup:
   `pod repo add avatarkit-specs https://github.com/spatius-ai/avatarkit-specs.git`),
   and this machine can push to that repo.

## 4. Local verification

> **Do not use bare `swift build` / `swift test`.** They target macOS and Agora
> ships iOS binaries only (`AgoraRtcKit/AgoraRtcEngineKit.h not found`). Every
> build below uses a specific iOS simulator id: the generic simulator destination
> also builds x86_64, which the main SDK does not ship (§8).

### 4.1 Unit tests

```bash
scripts/run-unit-tests.sh
```

Picks an available iPhone simulator (`SIMULATOR_ID=<udid>` overrides), builds
for testing into a temporary derived-data directory, ad-hoc signs the binary
frameworks (without this the bundle fails with *"Trying to load an unsigned
library"*), runs the tests, and prints `PASS|FAIL unit-tests: executed=<n>
failed=<n>`. Non-zero exit on any failure. If XCTest cannot even start its runner
on a busy machine ("Timed out while preparing execution worker"), the script
retries once. Coverage → [`test-cases.md`](test-cases.md) §1.

### 4.2 MOCK integration suite (gate)

Run on a device or an arm64 simulator:

```bash
xcodebuild build -project Demo/RTCDemo.xcodeproj -scheme RTCDemo \
  -destination 'platform=iOS Simulator,id=<udid>' CODE_SIGNING_ALLOWED=NO
```

(or open `Demo/RTCDemo.xcodeproj` and run). In the app: **Integration Test →
Mock (no network) → fill App ID / Avatar ID / Backend base URL → Run Mock →
Copy Report.** MOCK still loads the avatar for real, so it needs valid credentials
and network; it never touches Agora. Details and the report format →
[`test-cases.md`](test-cases.md) §2.

**Every MOCK case must PASS.** Keep the copied report; its `Result` line, the
`RTC SDK` / `Main SDK` header lines and the `Device` line go into §6.1. The
`RTC SDK` line must show the version being released.

The LIVE suite (Agora + backend token) is optional and not a gate — see
[`test-cases.md`](test-cases.md) §3.

### 4.3 Artifact check

```bash
scripts/check-release.sh pre
```

Checks, each printed as `PASS|FAIL <check>: <value>`:

- every version location (§2);
- both podspecs parse (`pod ipc spec`) with the expected version, source tag,
  platform and exact dependency set;
- `xcodebuild build -scheme AvatarKitRTC` succeeds for an iOS simulator;
- `CHANGELOG.md` has `## [<version>]` and no leftover `## [Unreleased]`;
- neither pod has the version in `avatarkit-specs` yet (fresh shallow clone of the spec repo);
- tag `v<version>` exists locally, both podspecs at the tag carry the version,
  and the tag is on `origin` with the same commit;
- offline xcframeworks (§6.2), **only if `dist/` has been built** (SKIP
  otherwise): each has exactly an `ios-arm64` device slice and an `ios-arm64`
  simulator slice and every slice's framework carries the version (numeric part
  only — `CFBundleShortVersionString` cannot hold an `-agora-special` suffix);
  the zip is named with the full version and `DEPENDENCIES.txt` names the full
  version and the podspecs' Agora pod (a stale `dist/` fails here).

`pod lib lint` / `pod spec lint` are not used: they are slow, and Agora's headers
emit `-Wdocumentation` warnings that fail lint without `--allow-warnings`.

The tag lines FAIL until §6 steps 4–5 are done; that is expected when running
this before tagging. **The run that counts is the one after the tag is pushed**
(§6 step 6) — that output goes into §6.1.

### 4.4 Documentation check

```bash
scripts/check-docs.sh
```

- the MOCK catalog block in `test-cases.md` matches `MockTestCases.all` (ids,
  order, groups) and is byte-identical to the web / Android RTC repos when they
  are checked out next to this one;
- `File.ext:N` / `File.ext:N-M` references in `README.md` and `docs/` (outside
  `decisions/` and `history/`) are within the file's length — files that are not
  in this repo are SKIP;
- every `.md` under `docs/` is registered in [`docs-map.md`](docs-map.md);
- every relative Markdown link in `README.md` and `docs/` points at an existing
  file;
- `release-process.md` here and in the sibling RTC repos carries the shared core
  sections (§1–§7 incl. 4.1–4.5 and 6.1, in order; platform-specific extras such
  as §6.2 / §8 are allowed).

It does not judge whether prose is still true; §5 does.

### 4.5 Dependency vulnerability check (required; report to the release owner)

**What is scanned:** only the runtime dependencies a host actually installs or
links; dev dependencies and build tooling are out of scope. The SPM resolution is the dependency set both channels pin (the podspecs pin the same versions); the main SDK is checked in its own release:

```bash
osv-scanner scan source -L Package.resolved
```

**Handling (hard rule):**

- **Report the result to the release owner whether or not anything is found**
  (report "0 findings" too).
- If anything is found, at any severity, **stop**: list each finding's package,
  version, CVSS / severity, fixed version and OSV link, plus whether our usage can
  reach it and the evidence (read the code — not from memory), and discuss it with
  the release owner.
- The release owner decides to **waive** it (reason goes into the execution
  summary) or **fix it before releasing**. The executor never waives on their own.

Tool: `brew install osv-scanner` (OSV database; the same tool on every platform).

## 5. Documentation alignment gate (hard gate)

`docs/architecture/` asserts how the code works **today**. Before every release
each file is re-read against the code being shipped:

| File | Verified against | Gate question |
|------|---------|---------|
| [`overview.md`](overview.md) | `AvatarKitRTC/Sources/AvatarKitRTC/` | Do the module split, provider abstraction, jitter constants, lifecycle paths and file table still hold? |
| [`telemetry-fields.md`](telemetry-fields.md) | `Utils/Telemetry.swift` and its call sites | Is the metric / event list complete? Have the known gaps changed? |
| [`test-cases.md`](test-cases.md) | `Demo/RTCDemo/Integration/`, `AvatarKitRTC/Tests/` | Does the LIVE table match `TestCases.swift`? Are prerequisites and report format current? (The catalog is checked by 4.4.) |
| [`release-process.md`](release-process.md) (this file) | podspecs, `Package.swift`, `scripts/`, `build-xcframework.sh` | Are the steps, commands and constraints still accurate? |
| [`docs-map.md`](docs-map.md) | the `docs/` file listing | Is every file registered and the verification stamp current? |

Plus `scripts/check-docs.sh` (4.4) passing.

Rules:

- Verifying means **reading the code**, not going from memory.
- Drift found is **fixed in the release commit itself**. Never release with
  "to be updated" — if a file cannot be brought up to date in time, postpone the
  release or revert the change.
- `docs/decisions/` is **not** in this gate: an accepted ADR is immutable; an
  overturned decision gets a new ADR and the old one is marked `superseded`.
  Pointer files for cross-SDK ADRs must still follow their source's status.
- Record which files were verified and what was fixed in the release commit
  message, and update the stamp in `docs-map.md`.

## 6. Release steps

CocoaPods trunk is read-only from 2026-12-02 (the CocoaPods team froze the public
Specs repo for security reasons, https://blog.cocoapods.org/CocoaPods-Specs-Repo/), so
both pods are published to our own spec repo
[`spatius-ai/avatarkit-specs`](https://github.com/spatius-ai/avatarkit-specs), shared with
`SpatiusAvatarKit`. Every version that used to be on trunk is mirrored there unchanged.

Validation clones the tag (the podspecs' `:git` source), so on iOS the tag is pushed
**before** the publish (web and Android publish first, then tag).

```bash
# 1. Bump every version location (§2); scripts/check-release.sh versions passes
# 2. CHANGELOG.md: move Unreleased into ## [<version>] — <date>
# 3. §4.1 unit tests, §4.2 MOCK suite, §4.4 docs check, §4.5 dependency check (report to the release owner), §5 alignment gate
# 4. Commit and tag
git commit -m "release: v<version>"
git tag v<version>
# 5. Push the branch and the tag (validation fails immediately without the tag)
git push origin main && git push origin v<version>
# 6. scripts/check-release.sh pre   — everything PASS
# 7. Write the execution summary (§6.1), then STOP at the human gate
# 8. After explicit confirmation — bridge first, then the main pod
cd AvatarKitRTC
pod repo push avatarkit-specs AvatarKitAgoraBridge.podspec --sources=avatarkit-specs,trunk --allow-warnings
pod repo push avatarkit-specs AvatarKitRTC.podspec --sources=avatarkit-specs,trunk
```

> **Human gate.** `pod repo push` publishes to a public repo that customers read on
> `pod install --repo-update` — treat it as an irreversible public release: once a
> customer has resolved a version, removing or rewriting its spec breaks their
> `Podfile.lock`, so a pushed version is never changed or removed. Run step 8 only
> after the release owner has explicitly confirmed, on the basis of §6.1.

> **Order cannot be reversed.** `AvatarKitRTC` depends on the exact
> `AvatarKitAgoraBridge` version; pushing it first fails dependency resolution.
> If the bridge push succeeded and the main pod failed, fix and push only the
> main pod — the bridge version is already taken.

> **`--allow-warnings`.** Validation compiles the bridge against Agora's
> headers, which emit `-Wdocumentation` warnings this repo cannot fix; without the
> flag the push fails on them. Bridge 1.1.0 was pushed with `--allow-warnings`. If
> the main pod's validation fails on the same header warnings only, re-run it with
> the flag too. Real errors still fail the push.

### 6.1 Execution summary (required at the gate)

List the **actual values and output** of this release, not "done":

| Row | What to report |
|-----|----------------|
| Versions and dependencies | Paste the `scripts/check-release.sh pre` version section |
| Unit tests | `scripts/run-unit-tests.sh` and its `executed=<n> failed=<n>` line |
| MOCK | The report's `Result` line, `RTC SDK` / `Main SDK` lines and `Device` line |
| Artifact check | The rest of `scripts/check-release.sh pre` output (podspecs, build, spec repo, tag) |
| Docs check | `scripts/check-docs.sh` output |
| Docs alignment gate | Which `architecture/` files were verified, and what was changed |
| Dependency vulnerability check | `osv-scanner` result (number of findings; each one listed) and the release owner's decision per finding |
| CHANGELOG | The `## [<version>]` entry, consistent with what actually changed |

> **Why actual values instead of ticks**: a tick cannot distinguish "did it" from
> "believed it was done". The Flutter SDK shipped 1.3.4 and 1.3.5 with the whole
> iOS xcframework inside the package (~67 MB extra each), both times claiming the
> artifact had been checked; 1.3.6 then shipped a stale version in README — a line
> its own process doc marked "must change on every release". A process document
> has no effect on an executor who does not read it; writing out the values makes
> "did not read it" visible at the gate.

### 6.2 Offline xcframework delivery (third channel)

`build-xcframework.sh` (repo root) produces `AvatarKitRTC.xcframework` +
`AvatarKitAgoraBridge.xcframework` and `AvatarKitRTC-<version>-xcframeworks.zip`
(both plus `DEPENDENCIES.txt`) in `dist/` (gitignored):

```bash
./build-xcframework.sh
```

It needs `cocoapods` + `xcodegen` and takes no input: the version, the main SDK
(`SpatiusAvatarKit` from `avatarkit-specs`), SwiftProtobuf and the Agora pod are all read
from the podspecs (`build-xcframework.sh:41-48`), so the same command builds the
public package on `main` and the special-SDK package on a §9 branch.
`DEPENDENCIES.txt` names exactly what the integrator must link alongside
(`:128-136`). Each xcframework has an arm64 device and an arm64 simulator slice;
both are **static**, and third-party dependencies are not embedded
(`build-xcframework.sh:10-12`). `scripts/check-release.sh pre` checks the slices
and the version once `dist/` exists (§4.3).

Attach the zip to the GitHub Release of the tag.

> **Hidden coupling**: `build-xcframework.sh:63` `sed`s `"AvatarKitRTC/Sources/`
> into `"Sources/` in staged copies of the podspecs (a remote checkout has the
> subdirectory prefix, a local `:path` does not). Changing the `source_files`
> prefix in the podspecs breaks this script.

## 7. Post-release

```bash
scripts/check-release.sh post
```

- `avatarkit-specs` has `Specs/<Pod>/<version>/` for **both** pods (fresh shallow clone);
- tag `v<version>` is on `origin`;
- a throwaway SPM package with `.package(url: …avatarkit-ios-rtc.git, exact:
  "<version>")` resolves, and the resolved `avatarkit-ios-rtc`,
  `avatarkit-ios-release` and `AgoraRtcEngine_iOS` versions are printed and
  checked — then the package, which `import`s `AvatarKitRTC`, is built for an
  iOS simulator;
- a throwaway app (xcodegen) installs `AvatarKitRTC` the way a customer does —
  `source` `avatarkit-specs` + `cdn.cocoapods.org`, our three pods from the spec repo,
  Agora and SwiftProtobuf from the CDN — with
  `use_frameworks! :linkage => :static` and builds for the simulator and for a
  device (unsigned). This is the clean-project integration that caught the
  simulator-architecture bug in `4e6c188` (§8); lint does not.

A spec repo push is a plain git push, so unlike trunk / the CDN there is no lag
and nothing is polled. The first SPM resolve on a machine downloads the AvatarKit and Agora binaries and can
take many minutes; later runs are fast.

Then, by hand:

1. **Public docs**: this repo has no standalone public docs — `README.md` points
   at the web rtc-adapter reference. If the API changed, assess whether that page
   needs an update.
2. If a decision was made this round, write an ADR →
   [`../decisions/`](../decisions/).

## 8. Platform-specific: simulator architecture exclusion (`4e6c188`)

`AvatarKitRTC.podspec:26-42` declares `EXCLUDED_ARCHS[sdk=iphonesimulator*] =
x86_64` **twice**: in `pod_target_xcconfig` and in `user_target_xcconfig`.

**Why both**: the main SDK's simulator slice is arm64-only, and **a dependency
pod's xcconfig does not propagate to the dependent pod's target**. Without its own
copy, the `AvatarKitRTC` target still builds x86_64, the whole AvatarKit module
fails to resolve, and every public type reports "cannot find in scope".

Only the Intel Mac simulator is excluded — which the main SDK never supported
(its Metal renderer and core binary are arm64-only). Apple Silicon simulators
work as usual. The same reason makes `generic/platform=iOS Simulator` builds fail
for the demo; use a specific simulator id.

> **`AvatarKitAgoraBridge.podspec` has no such exclusion** (only the C++17
> settings, `AvatarKitAgoraBridge.podspec:27-30`). It works today only because it
> depends on Agora alone (which has an x86_64 slice). **If the bridge ever pulls
> in a main-SDK symbol, the same bug returns.**

> `pod lib lint` cannot catch this class of problem — only the clean-project
> integration in §7 can.

## 9. Agora special builds (customer-specific Agora SDK)

Some customers run a build Agora makes for them — on iOS the separate pod
`AgoraRtcEngine_Special_iOS`, versioned like `4.5.2.191.BASIC`. The public pods
depend on `AgoraRtcEngine_iOS`; installing both puts two Agora SDKs in the app,
so such a customer needs a release of this package that depends on their
special pod instead. The code is identical — the special SDK has the same
`AgoraRtcKit` module and the 4.5.x callback signature — only the two podspecs'
Agora dependency changes.

**Naming — the Agora build is in the version, so it cannot be forgotten:**

| | Form | Example |
|---|---|---|
| Version (both pods) | `<base>-agora-special.<special Agora version>` | `1.2.0-agora-special.4.5.2.191.BASIC` |
| Tag | `v<version>` | `v1.2.0-agora-special.4.5.2.191.BASIC` |
| Branch | `agora-special/<special Agora version>` | `agora-special/4.5.2.191.BASIC` |
| Offline zip | `AvatarKitRTC-<version>-xcframeworks.zip` | `AvatarKitRTC-1.2.0-agora-special.4.5.2.191.BASIC-xcframeworks.zip` |

The `-` makes it a CocoaPods pre-release: `pod 'AvatarKitRTC'` and `~> 1.2` never
resolve to it; a customer gets it only by writing the full version.

**Channels:** CocoaPods (`avatarkit-specs`) and the offline zip. **Not SPM** — Agora ships no
special SDK over SPM; `Package.swift` on the branch keeps the public pin, and the
README there says so.

**Steps** (after the public `v<base>` release):

1. Branch `agora-special/<v>` from tag `v<base>`.
2. In both podspecs: `spec.version` → `<base>-agora-special.<v>`, the Agora
   dependency → `"AgoraRtcEngine_Special_iOS", "<v>"`, and
   `AvatarKitRTC.podspec`'s `AvatarKitAgoraBridge` dependency → the same version.
   Set `TelemetryIdentity.sdkVersion` and the demo's `TestRunner.rtcSDKVersion`
   to the full version too, so telemetry and test reports show which build ran.
   Add a short notice at the top of `README.md` (what Agora build, CocoaPods
   only).
3. Verify on a device with the special SDK: build the demo against it (the demo
   is SPM-based — stand in a local package named `AgoraRtcEngine_iOS` exposing
   `RtcBasic` from the special pod's xcframeworks), run MOCK and a real
   conversation. MOCK alone does not touch Agora.
4. `scripts/check-release.sh pre` — it recognises the version form and checks the
   podspecs against `AgoraRtcEngine_Special_iOS <v>`.
5. Commit, tag, push the branch and the tag; `pod repo push avatarkit-specs` both pods as in §6
   (Bridge first, `--allow-warnings` as needed).
6. `./build-xcframework.sh`, create a GitHub **pre-release** for the tag and
   attach the zip.
7. `scripts/check-release.sh post` — spec repo and a CocoaPods consumer build
   against the special pod; SPM is skipped.

The special branch is never merged back to `main`. A later public release that
the customer needs gets its own special build from that release's tag.

**Special builds released:**

| Version | Special Agora pod | Base | Date |
|---|---|---|---|
| `1.2.0-agora-special.4.5.2.191.BASIC` | `AgoraRtcEngine_Special_iOS 4.5.2.191.BASIC` | `v1.2.0` | 2026-10-20 |

## Related

- Docs map → [`docs-map.md`](docs-map.md)
- Architecture → [`overview.md`](overview.md)
- Telemetry → [`telemetry-fields.md`](telemetry-fields.md)
- Tests → [`test-cases.md`](test-cases.md)
- Version constant decision → [ADR-0001](../decisions/0001-telemetry-version-hand-written.md)
