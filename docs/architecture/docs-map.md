# Docs Map — iOS RTC SDK

Where everything under `docs/` lives, and which layer it belongs to.

The three directories and the five `architecture/` filenames are **identical in
all seven SDK repos** — spec → `docs/decisions/README.md` (umbrella repo
`avatarkit-sdks`).

## `architecture/` — current state

How this SDK works **right now**. Rewritten in place when the code changes.
Aligning these files with code fact is a hard release gate
(see the Documentation Alignment Gate section in this file).

**All five files were verified against code on 2026-08-27 at v1.0.1.**

| File | Purpose |
|------|---------|
| [`docs-map.md`](docs-map.md) | This file — what lives where under `docs/` |
| [`overview.md`](overview.md) | Internal architecture as it is today |
| [`release-process.md`](release-process.md) | Platform-specific build & publish steps |
| [`telemetry-fields.md`](telemetry-fields.md) | Telemetry events and fields emitted by this repo |
| [`test-cases.md`](test-cases.md) | Test case inventory |

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

_Empty — this repo had no pre-existing documentation to archive._

## Maintaining this file

Any commit that adds, moves, or deletes a file under `docs/` updates this map in
the same commit
