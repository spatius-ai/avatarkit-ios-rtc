# Docs Map — iOS RTC SDK

Where everything under `docs/` lives, and which layer it belongs to.

The three directories and the five `architecture/` filenames are **identical in
all seven SDK repos** — spec → `docs/decisions/README.md` (umbrella repo
`avatarkit-sdks`).

## `architecture/` — current state

How this SDK works **right now**. Rewritten in place when the code changes.
Aligning these files with code fact is a hard release gate
([`release-process.md`](release-process.md) §5).

**Verification stamp (v1.2.0 release gate, 2026-10-20).** `release-process.md`,
`test-cases.md` and this file were fully verified against code. In `overview.md`
the parts whose code changed since v1.1.0 (conversation state) and every line
reference were re-verified; `telemetry-fields.md` had no telemetry code change
since v1.1.0 and its line references were re-verified. Their last full
verification remains 2026-08-27 at v1.0.1 (version statements and the host SDK
dependency re-verified 2026-10-19 at v1.1.0). `scripts/check-docs.sh` checks the
mechanical part (catalog, line references, links, release-process sections, this
map).

| File | Purpose |
|------|---------|
| [`../README.md`](../README.md) | Entry point of `docs/`: the three layers and working rules |
| [`docs-map.md`](docs-map.md) | This file — what lives where under `docs/` |
| [`overview.md`](overview.md) | Internal architecture as it is today |
| [`release-process.md`](release-process.md) | Complete release procedure: versions, local verification, gates, publish, post-release |
| [`telemetry-fields.md`](telemetry-fields.md) | Telemetry events and fields emitted by this repo |
| [`test-cases.md`](test-cases.md) | Unit tests, MOCK suite + shared catalog, LIVE suite |

## `decisions/` — architecture decision records

Why the code is the way it is: the alternatives that were considered and
rejected. One file per decision, immutable once accepted — a reversed decision is
marked `superseded` and a new record written, never edited in place.

| File | Purpose |
|------|---------|
| [`README.md`](../decisions/README.md) | Index of this repo's ADRs |
| [`_TEMPLATE.md`](../decisions/_TEMPLATE.md) | ADR template |
| [`0001-telemetry-version-hand-written.md`](../decisions/0001-telemetry-version-hand-written.md) | ADR-0001 — Telemetry version stays hand-written, verified by a script |

## `history/` — archive

Documents predating this structure, frozen. Background only — never cite as
current state.

| File | Purpose |
|------|---------|
| [`README.md`](../history/README.md) | What the archive is for; its contents list (empty — this repo had no pre-existing documentation to archive) |

## Maintaining this file

Any commit that adds, moves, or deletes a file under `docs/` updates this map in
the same commit
