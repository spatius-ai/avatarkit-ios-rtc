# iOS RTC SDK Docs

Documentation for this repository, in three layers. **This layout is identical in
all seven SDK repos** — same directory names, same `architecture/` filenames.

| Layer | Directory | Meaning |
|-------|-----------|---------|
| Current state | [`architecture/`](architecture/) | How the SDK works **right now**. Rewritten in place as code changes. Present tense. |
| History | [`iterations/`](iterations/) | What was done, day by day. Append-only, never rewritten. Past tense. |
| Archive | [`history/`](history/) | Docs predating this structure. Frozen. Background only — never cite as current state. |

Full file listing → [`architecture/docs-map.md`](architecture/docs-map.md)

## Working rules

- **Every commit** appends an entry to `iterations/<today>.md`, in the same commit
  → `knowledge/workflows/commit-workflow.md`
- **Every release** re-verifies all of `architecture/` against the code being
  released — a hard gate → `knowledge/workflows/release-workflow.md` §1.1
- Layout and per-file contracts → `knowledge/docs-structure-spec.md`
- Anything that does not fit one of the five `architecture/` files goes to
  `iterations/` or `history/` — never a new `architecture/` filename, which would
  break cross-repo uniformity.

(Those documents live in the umbrella repo, `avatarkit-sdks`, and are the single
source of truth for all seven SDK repos. Do not fork them here.)

## Cross-SDK docs

Release gates, report schemas and the shared release framework live in
`sdk-release-manager/` and `knowledge/` in the umbrella repo, not in this repo.
