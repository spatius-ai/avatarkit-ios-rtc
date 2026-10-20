# iOS RTC SDK Docs

Documentation for this repository, in three layers. **This layout is identical in
all seven SDK repos** — same directory names, same `architecture/` filenames.

| Layer | Directory | Meaning |
|-------|-----------|---------|
| Current state | [`architecture/`](architecture/) | How the SDK works **right now**. Rewritten in place as code changes. Present tense. |
| Decisions | [`decisions/`](decisions/) | **Why** the code is this way: alternatives considered and rejected. One file per decision, immutable once accepted. |
| Archive | [`history/`](history/) | Docs predating this structure. Frozen. Background only — never cite as current state. |

Full file listing → [`architecture/docs-map.md`](architecture/docs-map.md)

## Working rules

- **A commit writes no docs by default** — the diff already carries what changed.
 An ADR is written only when a decision is made; `architecture/` is updated in
 the same commit when current behaviour moves

- **Every release** re-verifies all of `architecture/` against the code being
 released — a hard gate → [`architecture/release-process.md`](architecture/release-process.md) §5
- Layout and per-file contracts → `docs/decisions/README.md`
- Anything that does not fit one of the five `architecture/` files goes to
 `decisions/` or `history/` — never a new `architecture/` filename, which would
 break cross-repo uniformity.

(Those documents live in the umbrella repo, `avatarkit-sdks`, and are the single
source of truth for all seven SDK repos. Do not fork them here.)

## Cross-SDK docs

The release process for this repo is complete in
[`architecture/release-process.md`](architecture/release-process.md) (ADR-0002 in
`web-sdk`: each repo carries its own). The three RTC repos share its section
structure and the MOCK case catalog in
[`architecture/test-cases.md`](architecture/test-cases.md), kept byte-identical by
`scripts/check-docs.sh`. Cross-SDK principles live in `knowledge/` in the umbrella
repo.
