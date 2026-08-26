# Iteration Records

Append-only history of what was done in this repository, one file per calendar
day (`YYYY-MM-DD.md`), each containing one timestamped entry per commit.

## Rules

- **Append-only.** Entries are never rewritten to match later reality and never
  deleted. A stale entry is correct — it records what was true that day.
- **Past tense.** These files never state how the SDK works *now*. Current state
  lives in [`../architecture/`](../architecture/) and is rewritten in place.
- **One entry per commit**, added in the same commit as the code change.
- Multiple commits on one day append to the same dated file, newest at the bottom.

## Adding an entry

Copy a block from [`_TEMPLATE.md`](_TEMPLATE.md) into today's file.

Full rules → `knowledge/workflows/commit-workflow.md` in the umbrella repo
(`avatarkit-sdks`).

## Exemptions

Typo/formatting-only commits, merge commits without substantive conflict
resolution, and commits that only fix a prior iteration entry do not need an
entry. Everything else does — including dependency bumps and test-only changes.
