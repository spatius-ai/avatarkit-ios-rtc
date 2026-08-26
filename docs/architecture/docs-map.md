# Docs Map — iOS RTC SDK

Where everything under `docs/` lives, and which layer it belongs to.

The three directories and the five `architecture/` filenames are **identical in
all seven SDK repos** — spec → `knowledge/docs-structure-spec.md` (umbrella repo
`avatarkit-sdks`).

## `architecture/` — current state

How this SDK works **right now**. Rewritten in place when the code changes.
Aligning these files with code fact is a hard release gate
(→ `knowledge/workflows/release-workflow.md` §1.1).

**All five files were verified against code on 2026-08-26 at v1.0.0.**

| File | Purpose |
|------|---------|
| [`docs-map.md`](docs-map.md) | This file — what lives where under `docs/` |
| [`overview.md`](overview.md) | Internal architecture as it is today |
| [`release-process.md`](release-process.md) | Platform-specific build & publish steps |
| [`telemetry-fields.md`](telemetry-fields.md) | Telemetry events and fields emitted by this repo |
| [`test-cases.md`](test-cases.md) | Test case inventory |

## `decisions/` — architecture decision records

Append-only record of what was done, one file per day. Never rewritten to match
current reality.

| File | Purpose |
|------|---------|
| [`README.md`](../decisions/README.md) | Index of this repo's ADRs |
| [`_TEMPLATE.md`](../decisions/_TEMPLATE.md) | ADR template |

## `history/` — archive

Documents predating this structure, frozen. Background only — never cite as
current state.

_Empty — this repo had no pre-existing documentation to archive._

## Maintaining this file

Any commit that adds, moves, or deletes a file under `docs/` updates this map in
the same commit → `knowledge/workflows/commit-workflow.md`.
