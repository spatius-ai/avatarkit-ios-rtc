# iOS RTC — Decisions

Architecture Decision Records for this repo. One file per decision, recording
**why** the code is the way it is: the alternatives that were investigated and
rejected, and what the choice costs.

A diff shows what was chosen. It never shows what was rejected — which is exactly
what the next person re-litigates.

## Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| _none yet_ | | | |

## Writing one

Rules, criteria and worked examples → `knowledge/docs-structure-spec.md`.
The short version:

- **Write one only if** the decision is hard to reverse, crosses platforms, or
  constrains future work. Not for ports, bug fixes, config, renames, or version
  bumps — the commit already covers those.
- **Claude drafts, a human approves, and only then is the file written.** A
  declined draft is discarded, not filed.
- **Numbers are unique across all seven repos.** Check the highest number in use
  anywhere before allocating one.
- **Immutable once accepted.** A reversed decision is marked
  `superseded by ADR-NNNN`; a new record is written. The original stays readable.

## Cross-platform decisions

Written **once**, in the repo that owns the decision — usually web, but the
actual origin governs. Every other affected repo carries a file under the same
number whose body is a pointer: where the reasoning lives, plus where the
decision lands in *that* codebase. When the source ADR's status changes, every
pointer changes with it.
