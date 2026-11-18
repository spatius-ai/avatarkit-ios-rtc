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

### SDK license and third-party notices

**每次发布必做，适用于 GA、beta、rc 和 compat。** 在最终产物构建完成后、发布前执行；产物重新构建或许可文件发生变化后，重新执行本项。许可缺失、正文不一致、元数据错误或第三方声明未核清时，本项不得标为通过，也不得继续发布。

#### 1. 核对法务文本和版权主体

在本 SDK 仓库根目录执行：

```bash
python3 - <<'PYLICENSE'
from pathlib import Path
import hashlib
content = Path('LICENSE').read_bytes()
actual = hashlib.sha256(content).hexdigest()
expected = '092cc32970c36609b1f6a60812afe1f708590fe0ef083b910f3a2bd58062dfe7'
assert actual == expected, f'LICENSE differs from approved text: {actual}'
print('LICENSE PASS: SPATIALWALK PTE. LTD.; SHA-256=' + actual)
PYLICENSE
```

该摘要对应 2026-11-15 采用的法务全文（UTF-8、LF 换行），ToS 地址为 `https://www.spatius.ai/terms-of-service/`。以后正式更新许可文本时，七个 SDK 的正文和本项基准一起同步；不能为了让检查通过而单独改摘要。不同端的包元数据格式可以不同，许可正文必须相同。

#### 2. 核对元数据和最终交付包

- 两个 podspec 均声明 `Proprietary`、`:file => "LICENSE"`，从本次 tag 的源代码归档核对仓库根目录 LICENSE，与本地正文一致。
- `build-xcframework.sh` 的 CocoaPods 暂存目录也必须带 LICENSE。离线交付渠道发布时，对最终 ZIP 的三份许可做比较；本次不提供离线产物时，明确记录该渠道不适用：

```bash
python3 - /实际路径/release.zip <<'PYARTIFACT'
from pathlib import Path
import sys, zipfile
expected = Path('LICENSE').read_bytes()
with zipfile.ZipFile(sys.argv[1]) as package:
    for name in ['LICENSE', 'AvatarKitRTC.xcframework/LICENSE', 'AvatarKitAgoraBridge.xcframework/LICENSE']:
        assert package.read(name) == expected, name
        print('ZIP LICENSE PASS:', name)
PYARTIFACT
```

将示例路径换成本次实际交付 ZIP 的路径。

#### 3. 核对第三方声明

- 按本次版本的运行依赖、内嵌库和实际链接结果核对组件，区分随包分发、宿主另行引入、系统提供及仅构建/测试使用的依赖。
- 核对需要随包提供的许可和版权声明是否实际进入交付包（如 `THIRD_PARTY_NOTICES`、组件自带的 LICENSE/NOTICE）。逐项记录组件版本、声明文件所在位置；不能用我们的专有 LICENSE 替代第三方文本。
- 不把依赖清单、漏洞扫描通过或锁文件中出现的包，直接当成第三方声明检查已完成。缺失项须补齐后重新检查。

#### 4. 记录结果并复核发布版本

在下方“发布前执行结果清单”的许可检查行给出：SDK 版本、渠道、产物路径及 SHA-256、LICENSE 摘要、实际元数据值、包内许可路径和比较结果、第三方声明位置及核对结论。只写“已检查”不算通过。产物 SHA-256 可用 `shasum -a 256 <产物路径>` 获取。

发布后，从实际渠道重新下载本次版本，复核包内 LICENSE 和渠道许可元数据，记录结论。检查失败须报告具体差异，不覆盖旧版本来修复。特供线无需上传平台报告的既有约定不变，结果记录在本次发版执行清单中。


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
- If anything **not in the decision log below** is found, at any severity, **stop**: list each finding's package,
  version, CVSS / severity, fixed version and OSV link, plus whether our usage can
  reach it and the evidence (read the code — not from memory), and discuss it with
  the release owner.
- The release owner decides to **waive** it (reason goes into the execution
  summary) or **fix it before releasing**. The executor never waives on their own.
- **Record the release owner's answer in the decision log below right away** (date,
  advisory ID, package and version, decision, reason) and commit it with the release.
- When a later scan reports **an advisory ID already in the log** and the premise of
  its reason still holds (same usage; still not linked / still not calling the
  affected code / the fixed version still cannot be adopted), apply the logged
  decision without asking again and write "waived per decision log <date>" in the
  execution summary. If the premise no longer holds, or the advisory is not in the
  log, stop and discuss as above.

Tool: `brew install osv-scanner` (OSV database; the same tool on every platform).

**Decision log** (append only: when a decision is withdrawn, add a new row saying so;
never edit an old row):

| Date | Advisory | Package / version | Decision | Reason |
|---|---|---|---|---|
| (none yet) | | | | |

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
| SDK 许可与第三方声明 | 本文 SDK license and third-party notices 四步检查结果：版本/渠道、产物及 SHA-256、正文摘要、实际元数据、包内许可路径及比较结果、第三方声明核对结论 |
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
(both plus `DEPENDENCIES.txt` and `LICENSE`) in `dist/` (gitignored):

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

**许可复核（必须）**：从实际发布渠道下载本次版本，按前文许可检查流程复核包内 LICENSE 和渠道元数据，记录实际结果；不能仅复用本地检查结论。

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
| `1.2.0-agora-special.4.5.2.191.BASIC-compat-ios13` (§10) | `AgoraRtcEngine_Special_iOS 4.5.2.191.BASIC` | `v1.2.0-agora-special.4.5.2.191.BASIC` | 2026-11-02 |

## 10. compat-ios13 builds (iOS 13 deployment target)

A customer's app deploys to iOS 13–15 and routes by OS version itself (below 16 it
does not use AvatarKit). The requirement is only: an app with a 13.0 deployment
target compiles and links, and launches on 13–15 without crashing. **Features on
13–15 are not supported.** The main SDK has the matching build — its
`release-process.md` §13 (`compat/ios13`, `<base>-compat-ios13`).

The build is cut from the customer's Agora channel: this customer runs the §9
special SDK, so the branch is `compat/ios13-agora-<special Agora version>` from the
§9 branch, never merged back.

| | Form | Example |
|---|---|---|
| Version (both pods) | `<§9 version>-compat-ios13` | `1.2.0-agora-special.4.5.2.191.BASIC-compat-ios13` |
| Tag | `v<version>` | `v1.2.0-agora-special.4.5.2.191.BASIC-compat-ios13` |
| Branch | `compat/ios13-agora-<special Agora version>` | `compat/ios13-agora-4.5.2.191.BASIC` |
| Offline zip | `AvatarKitRTC-<version>-xcframeworks.zip` | `AvatarKitRTC-1.2.0-agora-special.4.5.2.191.BASIC-compat-ios13-xcframeworks.zip` |

`scripts/check-release.sh` strips the `-compat-ios13` suffix before reading the Agora
version, and expects a 13.0 minimum iOS for such a version. Release steps are §9's.

Differences from that base, and nothing else:

1. Deployment target 16.0 → 13.0: `Package.swift`, both podspecs. Agora's pods
   declare iOS 8.0 and the 4.5.2.191.BASIC binaries are built for 9.0.
2. Every top-level declaration in sources and tests is `@available(iOS 16.0, *)`.
   A host that calls AvatarKitRTC outside `if #available(iOS 16.0, *)` gets a
   compile error. The ObjC++ bridge needs no change.
3. Main SDK dependency → `<main>-compat-ios13` on both channels (the public main
   SDK declares 16.0 and cannot be imported from a 13.0 target).

Verify: unit tests; an empty app with a 13.0 deployment target compiles and links
with the `#available` gate, fails to compile without it, and launches into the SDK
branch on a 16+ simulator. Launch on 13–15 cannot be checked locally
(CoreSimulator refuses iOS 13/14 runtimes on hosts after macOS 12.99) — the
customer confirms on their devices.

## Related

- Docs map → [`docs-map.md`](docs-map.md)
- Architecture → [`overview.md`](overview.md)
- Telemetry → [`telemetry-fields.md`](telemetry-fields.md)
- Tests → [`test-cases.md`](test-cases.md)
- Version constant decision → [ADR-0001](../decisions/0001-telemetry-version-hand-written.md)

### 2026-11-18 upgrade validation

`compat/ios13-agora-4.5.3.3.BASIC` keeps the 1.2.0 RTC implementation and changes
only the dependency/version metadata to Agora Special 4.5.3.3.BASIC and
SpatiusAvatarKit 1.3.9-compat-ios13. This release allows `~> 4.5.0.BASIC` in both pods (4.5.x including
special prerelease versions, excluding 4.6). The version suffix records the
tested baseline, not an exact Agora constraint. The customer owns compatibility
validation for their selected Agora build. Publish matching Bridge + RTC versions
after the main SDK; the old published pods retain their original exact constraints.

Validation: existing ObjC++ bridge compiles unchanged for arm64 device/simulator
with an iOS 13 target; 10/10 RTC unit tests pass with the new special SDK; a Swift 5
CocoaPods host using the actual main XCFramework builds for device and simulator,
and fails compilation as expected without the iOS 16 availability gate. All
embedded device frameworks have minimum iOS <= 13. Simulator launch passed on
iOS 17.5. On iPhone 12 Pro (iOS 26.6.1), connection + PCM/animation smoke passed
5/5, observing 10 frames and then 26/5 frames across two additional PCM sessions.
No claim is made about launch on an actual iOS 13–15 device; that remains a
customer-device check. SwiftProtobuf duplicate Objective-C class warnings are
visible with the self-contained main binary plus RTC's Protobuf dependency; the
checks above passed, but this validation does not claim those warnings are fixed.

Release report evidence: RTC Mock 44/44 on iPhone13,3 / iOS 26.6.1, user-exported Copy Report timestamp 2026-11-18T14:26:23Z; case IDs match the complete source catalog. Main integration coverage is 88/88 (full run plus baked-asset rerun); performance has 10 measured rounds. Render metrics match public 1.3.9, including its existing ultra WATCH for aed008e4-8ddf-41aa-b5b2-5d7321dd4165. Reports are retained locally, not uploaded, per the release owner.
