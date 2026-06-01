# Fork-sync automation for `freitasjca/mORMot2` (subset variant)

Authoritative, self-contained reference for the GitHub Actions workflow that
maintains `freitasjca/mORMot2` as a **curated subset** of upstream
`synopse/mORMot2` — containing only the files that `horse-provider-mormot`
and its transitive dependencies need, regenerated daily.

This document captures everything: design rationale, every staged file
(workflow, walker, seed, Boss manifest, deployment runbook), how the workflow
behaves day to day, how to deploy it, how to extend it, and how it differs
from the Delphi-Cross-Socket fork-sync system. It is the single source of
truth for the mORMot2 subset-fork system.

For the sibling system, see
[`patches/horse-provider-crosssocket/doc/fork-sync-automation.md`](../../horse-provider-crosssocket/doc/fork-sync-automation.md)
(the Delphi-Cross-Socket full-mirror variant).

---

## Table of contents

1. [Background and intent](#1-background-and-intent)
2. [What was prepared](#2-what-was-prepared)
3. [The staged files in full](#3-the-staged-files-in-full)
   - [3.1 `boss.json`](#31-bossjson)
   - [3.2 `.sync/seed.txt`](#32-syncseedtxt)
   - [3.3 `.sync/walk-uses.sh`](#33-syncwalk-usessh)
   - [3.4 `.sync/README.md` (ships into fork)](#34-syncreadmemd-ships-into-fork)
   - [3.5 `.github/workflows/sync-upstream.yml`](#35-githubworkflowssync-upstreamyml)
   - [3.6 `INSTRUCTIONS.md` (deployment runbook)](#36-instructionsmd-deployment-runbook)
4. [How the workflow works step by step](#4-how-the-workflow-works-step-by-step)
5. [Operational behaviour](#5-operational-behaviour)
6. [What's safe to tune / what must not change](#6-whats-safe-to-tune--what-must-not-change)
7. [Differences vs the Delphi-Cross-Socket fork-sync workflow](#7-differences-vs-the-delphi-cross-socket-fork-sync-workflow)
8. [End-state when upstream merges Boss tooling](#8-end-state-when-upstream-merges-boss-tooling)
9. [Cross-references](#9-cross-references)
10. [Appendix · staging-folder location](#10-appendix--staging-folder-location)

---

## 1. Background and intent

### Why a fork at all

`horse-provider-mormot` needs `boss install` to pull mORMot2 source alongside
Horse. Upstream `synopse/mORMot2` has no `boss.json` — Synopse maintains
mORMot2 independently of the Boss package ecosystem, and an upstream PR to
add Boss tooling files would be cosmetic for them and is unlikely to be
prioritised. The fork exists to **layer Boss metadata onto the upstream
source** so consumers can write a single
`"github.com/freitasjca/mORMot2": ">=2.3.0"` dependency.

### Why a subset, not a full mirror

mORMot2 is large: ~144 source files across `core/`, `db/`, `orm/`, `rest/`,
`soa/`, `crypt/`, `net/`, `lib/`, `app/`, plus extensive `static/`, `test/`,
`packages/`, `ex/`, and documentation. `horse-provider-mormot` uses six
top-level units (all in `core/` and `net/`), whose transitive closure is
**47 files**. The full mORMot2 tree weighs hundreds of MB; a full-mirror
fork would clone all of it into every consumer's `modules/mORMot2/`.

The subset model trims the file count to roughly a third of upstream, and
a much smaller fraction of byte size (since dropped modules contain large
database driver code, extensive tests, and static binary blobs).

### Operational philosophy

- **Upstream is the source of truth.** The fork tree is regenerated on every
  sync — never edited by hand.
- **Seed-driven manifest.** `.sync/seed.txt` lists the directly-imported
  units. Everything else is auto-discovered by the walker.
- **No source patches.** Unlike the Delphi-Cross-Socket fork (which carries
  mTLS additions), the mORMot2 subset is bit-for-bit identical to upstream
  for every file present.
- **Closure correctness is enforced.** A post-walk integrity check fails the
  workflow if any `uses` reference in a manifested file points at a
  non-manifested unit.
- **Silent on success.** Daily cron, no notifications when things work.
  Failure auto-opens a GitHub issue with a recovery runbook.

---

## 2. What was prepared

Six artefacts staged in `/workspaces/horse-crosssocket/mormot2-fork-sync-action/`
(this workspace's staging location — deployment target is
`freitasjca/mORMot2`'s own checkout):

```
mormot2-fork-sync-action/
├── INSTRUCTIONS.md                                 ← Windows-side deployment runbook
├── boss.json                                       ← minimal Boss manifest
├── .github/
│   └── workflows/
│       └── sync-upstream.yml                       ← the workflow (~190 lines)
└── .sync/
    ├── README.md                                   ← in-repo design doc (ships into fork)
    ├── seed.txt                                    ← 6 directly-imported mormot.* units
    └── walk-uses.sh                                ← transitive-closure walker (bash, ~155 LOC)
```

Validation summary (2026-05-30, against `synopse/mORMot2@master`):
- Walker emits a 47-file manifest with zero unresolved references.
- Closure-completeness check passes — every `uses mormot.*` token in the
  manifested files resolves to another manifest entry.
- Folder breakdown: 26 `core`, 8 `lib`, 6 `net`, 4 `crypt`, 3 top-level
  shared includes.

---

## 3. The staged files in full

### 3.1 `boss.json`

Minimal record so `boss install github.com/freitasjca/mORMot2` works.

```json
{
  "name": "mORMot2",
  "description": "Synopse mORMot2 framework — curated subset fork carrying only the units transitively required by horse-provider-mormot and its dependencies. Maintained in lockstep with synopse/mORMot2 via an automated daily sync workflow. See .sync/README.md for the manifest model.",
  "version": "2.3.10000",
  "homepage": "https://github.com/freitasjca/mORMot2",
  "license": "MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later",
  "mainsrc": "src/",
  "browsingpath": "src/",
  "projects": [],
  "dependencies": {}
}
```

Notes:
- `name: "mORMot2"` — short name; Boss prepends `github.com/<owner>/` from
  whatever dependency-string the consumer wrote.
- `mainsrc` and `browsingpath` are both `src/` — Boss appends these to the
  Delphi search path of any consumer project. The subset preserves
  upstream's directory layout under `src/`, so search-path resolution works
  identically to using full mORMot2.
- `license` reflects mORMot2's actual MPL/GPL/LGPL tri-license.
- `dependencies: {}` — mORMot2 has no third-party Pascal dependencies.
- `version` is a placeholder following Synopse's 5-digit minor scheme. The
  workflow does **not** auto-bump this — currently a manual touch when you
  cut a fork release. Consumers usually pin via tag (see §4, "Mirror
  upstream tags").

### 3.2 `.sync/seed.txt`

Six lines, derived mechanically from:

```bash
grep -rhnE 'mormot\.[a-z0-9._]+' horse-provider-mormot/src/*.pas \
  | grep -oE 'mormot\.[a-z0-9._]+' \
  | sed -E 's/\.pas$//' \
  | sort -u
```

The lowercase filter excludes false positives from Horse type names like
`THorseProvider.Mormot.Pool`.

Content:

```
# mORMot2 subset-fork seed set
#
# One mORMot2 unit name per line. Walker walks the transitive 'uses' + '{$I .inc}'
# closure of these units and emits the manifest used by the daily sync workflow.
#
# Origin: extracted from `grep -oE 'mormot\.[a-z0-9._]+' horse-provider-mormot/src/*.pas`
# (the lowercase-only filter excludes false positives from Horse type names like
# 'THorseProvider.Mormot.Pool').
#
# Add new entries here only when horse-provider-mormot itself starts importing a
# new top-level mORMot2 unit. Transitive dependencies are auto-discovered by the
# walker — do not list them here.

mormot.core.base
mormot.core.buffers
mormot.core.text
mormot.core.unicode
mormot.net.http
mormot.net.server
```

### 3.3 `.sync/walk-uses.sh`

Pure bash, no dependencies beyond POSIX tools. BFS over `uses` clauses and
`{$I/$include}` directives starting from the seed units. Outputs the sorted
manifest of paths relative to `src/`, one per line.

Key semantics:

| Aspect | Behaviour |
|---|---|
| `set -uo pipefail` (not `set -e`) | grep "no-match" exits are normal in the walker — `set -e` would treat them as fatal. Errors are surfaced via explicit `exit 3`. |
| Comment-safe `uses` extraction | Scopes to `\<uses\>[^;]+;` regions so doc-string mentions of `mormot.core.crypt` are not treated as deps |
| `.inc` directive forms | Handles `{$I file}`, `{$INCLUDE file}`, `{$include file}` — both with and without `..\` prefixes, both `\` and `/` separators |
| `{$I %MACRO%}` exclusion | Compiler macros like `{$I %FPCVERSION%}` are excluded via `[^}%]` lookahead |
| Unit name → file path | `mormot.<folder>.<rest>` → `<folder>/mormot.<folder>.<rest>.pas` (verified 100% consistent across mORMot2 as of 2026-05-30) |
| Top-level shared includes | `mormot.commit.inc`, `mormot.defines.inc`, `mormot.uses.inc` added unconditionally up front — they're transitively reachable, but adding them eagerly is harmless and protects against future seed sets that don't reach them |
| Bare `.inc` filename resolution | If `{$I file.inc}` has no folder prefix, walker probes the parent folder of the current unit, then falls back to a `find` across `src/` |
| Unresolvable `.inc` | Stderr warning, walking continues — some references are conditional and never fire on the platforms we care about |
| Unresolvable unit (`uses mormot.foo;` where no file exists) | Hard fail with exit code 3 — signals workflow that the closure is broken |
| Token-not-a-unit guard | Tokens ending `.inc` are excluded from unit-resolution (they're includes, handled separately) |

The full script lives at `mormot2-fork-sync-action/.sync/walk-uses.sh`.

Usage:

```bash
walk-uses.sh <seed-file> <upstream-mormot2-root>
```

Output: sorted manifest on stdout, warnings on stderr, exit 0 on success,
exit 3 on unresolvable unit.

### 3.4 `.sync/README.md` (ships into fork)

Companion doc that lives **inside the fork** so future maintainers find the
design rationale next to the patches. Documents:

- The role of `.sync/` (workflow's stable source of truth; survives the
  daily reset because the workflow preserves it through `/tmp`)
- Manifest-vs-walker architecture in one paragraph
- `seed.txt` rules (one unit per line, transitive deps NOT listed, origin
  command for regeneration)
- `walk-uses.sh` semantics table (the same table as §3.3 above)
- The closure-completeness verification check (inlined for reference)
- Procedure for updating the manifest when `horse-provider-mormot` starts
  importing a new top-level mORMot2 unit

### 3.5 `.github/workflows/sync-upstream.yml`

Daily at 04:23 UTC (offset from the Delphi-Cross-Socket fork's 04:17 slot
to avoid runner-queue contention). Inputs:

```yaml
on:
  schedule:
    - cron: '23 4 * * *'
  workflow_dispatch:
    inputs:
      force_resync:
        description: 'Force resync even if upstream HEAD matches last-synced marker'
        required: false
        default: 'false'
```

Permissions:

```yaml
permissions:
  contents: write   # force-push master, update marker tag, push mirrored tags
  issues:   write   # failure-notification issue creation
```

Environment:

```yaml
env:
  UPSTREAM_REPO: https://github.com/synopse/mORMot2.git
  FORK_BRANCH:   master
  MIRROR_BRANCH: ''     # mORMot2 fork tracks only master
  TAG_GLOB:      'v*'   # 'v*' = release tags only; '*' = all; '' = skip
```

The thirteen workflow steps are described in detail in §4.

### 3.6 `INSTRUCTIONS.md` (deployment runbook)

Windows-side step-by-step procedure for first-time setup:

1. **Create the fork on GitHub.** Fork `synopse/mORMot2` to `freitasjca/mORMot2`.
   Copy master branch only.

2. **Clone the fork locally.** `git clone https://github.com/freitasjca/mORMot2.git`
   into `C:\lang\Repo\mORMot2`.

3. **Copy the staged files into the fork.** From WSL/Git Bash:

   ```bash
   SRC=/mnt/c/lang/Repo/horse-crosssocket/mormot2-fork-sync-action
   DEST=/mnt/c/lang/Repo/mORMot2

   mkdir -p "$DEST/.github/workflows" "$DEST/.sync"
   cp "$SRC/.github/workflows/sync-upstream.yml"   "$DEST/.github/workflows/"
   cp "$SRC/.sync/README.md"                       "$DEST/.sync/"
   cp "$SRC/.sync/seed.txt"                        "$DEST/.sync/"
   cp "$SRC/.sync/walk-uses.sh"                    "$DEST/.sync/"
   chmod +x "$DEST/.sync/walk-uses.sh"
   cp "$SRC/boss.json"                             "$DEST/"
   cp "$SRC/INSTRUCTIONS.md"                       "$DEST/"
   ```

4. **Verify the walker locally** (optional but recommended):

   ```bash
   cd "$DEST"
   .sync/walk-uses.sh .sync/seed.txt . | wc -l
   # Expected: 47 (give or take a few as upstream evolves)
   ```

5. **Commit and push** the staging files to master. The fork still contains
   the full mORMot2 source tree at this point; the first workflow run will
   replace it with the subset.

6. **Enable Actions write permissions:** Settings → Actions → General →
   Workflow permissions → "Read and write permissions". Confirm no
   branch-protection rule on master blocks force-push.

7. **Trigger the first run** manually: Actions → "Sync from upstream
   (mORMot2 subset)" → Run workflow (leave `force_resync: false`).

8. **Wire `horse-provider-mormot/boss.json`** to depend on the fork:

   ```json
   {
     "dependencies": {
       "github.com/HashLoad/horse": ">=3.2.0",
       "github.com/freitasjca/mORMot2": ">=2.3.0"
     }
   }
   ```

Post-first-run expected state:

```
freitasjca/mORMot2/
├── .github/workflows/sync-upstream.yml
├── .sync/{README.md,seed.txt,walk-uses.sh}
├── boss.json
├── LICENSE         (preserved from upstream)
├── README.md       (preserved from upstream)
└── src/            (47 files: core/, crypt/, lib/, net/, 3 top-level .inc)
```

---

## 4. How the workflow works step by step

```
1.  Checkout fork (master, full depth — needed to read the marker tag)
2.  Configure git identity (github-actions[bot])
3.  Preserve fork-only files          ─── cp -a .sync .github boss.json
                                          .gitignore LICENSE README.md
                                          CHANGELOG.md → /tmp/preserve
4.  Clone upstream + fetch tags       ─── git clone --depth 1 + tag fetch
5.  Detect upstream change            ─── compare upstream HEAD vs
                                          last-synced-upstream tag
─── if no_change AND force_resync != true: jump to step 12 ───
6.  Run walker → /tmp/manifest.txt
7.  Verify closure completeness       ─── for every manifest .pas, every
                                          'uses mormot.*' token must resolve
                                          to a manifest entry
8.  Reset fork tree to subset         ─── rm -rf src/ static/ test/
                                          packages/ res/ doc/ docs/ ex/
                                          tools/ script/ CONTRIBUTORS.md
                                          LICENCE.md DONATE.md kompare.sh
                                          commit.sh get_latest_static.sh
                                          ; mkdir src/
                                          ; cp manifest files in
9.  Restore fork-only files           ─── cp -a /tmp/preserve/* back
10. Commit, push master, mirror branch (if MIRROR_BRANCH set)
11. Mirror upstream tags              ─── for each upstream tag matching
                                          TAG_GLOB, point it at HEAD on
                                          the fork; push --tags
12. Update last-synced-upstream tag   ─── git tag -f last-synced-upstream
                                          upstream-sha ; push -f
13. On failure: open issue            ─── via actions/github-script@v7,
                                          body = recovery runbook
```

### Reset-and-rebuild pattern (vs reset-and-restore)

The Delphi-Cross-Socket workflow does `git reset --hard upstream/master` then
copies fork-only files back. The mORMot2 workflow **doesn't reset to
upstream's HEAD** — instead it removes upstream-shaped top-level paths
entirely, then copies in only the manifest files:

```bash
for path in src static test packages res doc docs ex tools script \
            CONTRIBUTORS.md LICENCE.md DONATE.md kompare.sh \
            commit.sh get_latest_static.sh; do
  [ -e "$path" ] && rm -rf "$path"
done
mkdir -p src
while IFS= read -r rel; do
  mkdir -p "src/$(dirname "$rel")"
  cp "/tmp/upstream/src/$rel" "src/$rel"
done < /tmp/manifest.txt
```

The cleared-paths list is curated. If upstream adds a new top-level directory
in future (e.g. `wasm/`), it will silently accumulate in the fork until
someone adds it to this list. Worth periodically checking.

### Closure-completeness check

Run inline as step 7. For each `.pas` in the manifest, every `mormot.*`
token inside a `uses` clause body must resolve to another manifest entry:

```bash
MANIFEST=/tmp/manifest.txt
ROOT=/tmp/upstream/src
missing=$(mktemp)
while IFS= read -r f; do
  [[ $f == *.pas ]] || continue
  tr '\n' ' ' < "$ROOT/$f" \
    | grep -ioE '\<uses\>[^;]+;' \
    | grep -oE 'mormot\.[a-zA-Z0-9._]+' 2>/dev/null \
    | grep -v '\.inc$' || true
done < "$MANIFEST" | sort -u | while read -r dep; do
  folder=$(echo "$dep" | cut -d. -f2)
  grep -qxF "$folder/${dep}.pas" "$MANIFEST" || echo "$dep" >> "$missing"
done
[ -s "$missing" ] && { cat "$missing"; exit 1; }
```

If anything is missing, the workflow fails with `::error::Closure incomplete`
and the auto-opened issue lists the missing references. This is the safety
net for walker bugs — if the regex misses a `uses` construct (e.g. unusual
conditional compilation around it), the missing unit shows up here rather
than as a downstream consumer build break.

### Tag mirroring (the boss-compatibility key)

```bash
for tag in $(git -C /tmp/upstream tag -l "$TAG_GLOB"); do
  if ! git rev-parse "refs/tags/$tag" >/dev/null 2>&1; then
    git tag "$tag" HEAD
  fi
done
git push origin --tags
```

Upstream tags like `v2.3.10000` are re-pointed at the **fork's** HEAD commit
(not upstream's). This is what lets a consumer write:

```json
"github.com/freitasjca/mORMot2": ">=2.3.0"
```

and have Boss resolve against a matching tag that exists on the fork — even
though the fork's HEAD content (subset) differs from upstream's tagged
commit content (full).

### Idempotency: `last-synced-upstream` marker tag

A lightweight git tag pointing at the upstream SHA used in the last
successful sync. Step 5 compares it against `upstream/HEAD`:

- Equal → exit in ~30 s (no work)
- Different → upstream advanced; do the full regenerate
- `force_resync: true` → bypass the check

The marker tag is updated at the **end** of the workflow (step 12), after
a successful push. If any prior step fails, the tag stays pinned to the
previous good SHA, so the next run retries.

---

## 5. Operational behaviour

| Scenario | Workflow outcome | Notification |
|---|---|---|
| Daily cron, upstream unchanged | ~30 s no-op | None |
| Daily cron, upstream advanced, closure clean | Walker regenerates manifest; tree rebuilt; force-push master; mirror new tags; advance marker | None |
| Daily cron, walker fails (unresolved unit) | Workflow fails at step 6; issue auto-opened; fork stays at previous good state | Issue with `sync` + `needs-attention` labels |
| Daily cron, closure incomplete | Workflow fails at step 7 with `::error::Closure incomplete — walker missed these references: …`; fork unchanged | Same |
| `seed.txt` updated to add a new top-level unit | Same as upstream-advanced — next sync (or manual `force_resync`) picks it up | None on success |
| `workflow_dispatch` with `force_resync: true` | Bypasses marker; full regenerate even if upstream unchanged | Failure issue if any step fails |
| Transient network / cnvcl unreachable (n/a for mORMot2 — no cnvcl dep) | n/a | n/a |

### Failure-mode issue body

The auto-created issue covers the three likely causes:

1. **Walker found an unresolvable `uses` reference.** Upstream introduced a
   new unit naming convention or the seed needs updating.
2. **Closure completeness check failed.** A `uses` clause in a manifested
   file references a `mormot.*` unit the walker didn't pick up — likely a
   walker regex gap.
3. **`seed.txt` is stale.** `horse-provider-mormot` started importing a new
   top-level mORMot2 unit but the seed wasn't updated. Add the unit to
   `seed.txt` and trigger `workflow_dispatch` with `force_resync: true`.

Resolution steps (embedded in the issue body, runnable as copy-paste):

```
1. Clone the fork locally and clone upstream to /tmp/upstream.
2. Run the walker manually: .sync/walk-uses.sh .sync/seed.txt /tmp/upstream
3. If it reports unresolved units, update .sync/walk-uses.sh (probably
   the unit-name-to-path mapping) or add the missing units to seed.txt.
4. Run the closure-completeness check (the inline script in this workflow)
   locally to confirm a clean state.
5. Commit, push, re-run this workflow.
```

---

## 6. What's safe to tune / what must not change

### Tunable

| Setting | Where | Notes |
|---|---|---|
| Cron schedule | `on.schedule.cron` | 04:23 UTC default. Offset from the Delphi-Cross-Socket fork's 04:17 slot to avoid runner-queue contention. Avoid hour boundaries (best-effort scheduling defers ~5–10 min at peak). |
| `TAG_GLOB` | workflow `env:` | `'v*'` (default) mirrors only release tags. `'*'` mirrors everything. `''` skips tag mirroring entirely. |
| `MIRROR_BRANCH` | workflow `env:` | Empty by default — mORMot2 fork only tracks master. Set to e.g. `'dev'` if you ever add a parallel branch. |
| Seed set | `.sync/seed.txt` | Add a new top-level mORMot2 unit when `horse-provider-mormot` starts importing one. Transitive deps are walker-derived; do **not** list them. |
| Cleared-paths list | workflow step "Reset fork tree to manifest subset" | The set of top-level upstream directories removed before manifest files are copied in. Extend if upstream introduces new top-level dirs. |

### Do not change

- **`.sync/` location.** Must stay at the repo root. Moving it under `src/`
  or any upstream-shaped path would have it cleared by the reset step.
- **`last-synced-upstream` tag.** Never delete manually. Use
  `force_resync: true` to force a regenerate instead.
- **Files under `src/`.** Hand edits are lost on the next sync. If a
  fork-only modification ever becomes necessary, follow the patch-overlay
  model from `crosssocket-fork-sync-action/.sync/patches/` — but this
  should be a last resort; the strong preference is to file an upstream
  PR.
- **`walk-uses.sh` set-flag policy.** It uses `set -uo pipefail`, not
  `set -e`. Adding `-e` would make grep "no match" exit codes fatal and
  break the walker on the first hand-off between empty pipes.

---

## 7. Differences vs the Delphi-Cross-Socket fork-sync workflow

| Aspect | DCS fork (`crosssocket-fork-sync-action/`) | mORMot2 subset fork (`mormot2-fork-sync-action/`) |
|---|---|---|
| Sync model | Full mirror, reset to upstream, overlay patches | Curated subset, regenerate from seed + walker |
| Source patches | 2 `.patch` files (mTLS to `Net.CrossSslSocket.*`) | None |
| External deps vendored | CnPack subset (15 files from `cnpack/cnvcl`) | None |
| Fork size vs upstream | 100% + 15 files | ~33% (~47 of ~144) |
| Walker | n/a | `.sync/walk-uses.sh` (~155 LOC bash) |
| Closure verification | n/a | Inline integrity check (step 7) |
| Tag mirroring | Single fork-tagged release (`v1.0.3`) | All upstream `v*` tags re-pointed at fork HEAD |
| Failure mode | `git apply --3way` couldn't merge a patch | Walker found unresolvable ref OR closure incomplete |
| Failure-rate (expected) | Rare — fires when upstream rewrites `Net.CrossSslSocket.*` around mTLS anchors | Slightly more frequent — fires when upstream introduces a non-standard `uses`/`{$I}` form OR when `horse-provider-mormot` imports a new top-level unit without `seed.txt` being updated first |
| Failure-recovery effort | Manually graft mTLS onto new upstream files; regenerate patches | Either: update seed (trivial), or update walker regex (small bash edit) |
| Cron slot | 04:17 UTC | 04:23 UTC |

---

## 8. End-state when upstream merges Boss tooling

This is the parallel of "when the mTLS PR lands" for the DCS fork. The
mORMot2 fork's reason to exist disappears if Synopse ever accepts a
`boss.json` upstream. Retirement procedure:

1. Confirm `synopse/mORMot2@master` carries a `boss.json` compatible with
   consumer expectations (correct `name`, `mainsrc`, license).
2. Update `horse-provider-mormot/boss.json` to depend directly on
   `github.com/synopse/mORMot2`. Note the consumer-side size impact —
   they'll now pull full mORMot2.
3. Run the workflow once with `force_resync: true`. The fork's master is
   regenerated as a subset that nobody depends on anymore.
4. Archive the fork repo with a redirect note pointing to upstream.

Until step 1 happens — and even after, if the subset size advantage remains
valuable — the fork continues to provide a smaller `boss install` footprint.

The workflow can stay running until step 4 — it provides defence-in-depth
against accidental drift even during transition.

---

## 9. Cross-references

- [`patches/horse-provider-crosssocket/doc/fork-sync-automation.md`](../../horse-provider-crosssocket/doc/fork-sync-automation.md)
  — full-mirror sibling system (Delphi-Cross-Socket fork)
- [`patches/horse-provider-mormot/README.md`](../README.md) —
  primary consumer-facing install docs
- [`architecture-diagrams.md`](architecture-diagrams.md) —
  mORMot2 provider request lifecycle
- [`implementation-notes.md`](implementation-notes.md) —
  provider-side implementation log
- [`middleware-compatibility.md`](middleware-compatibility.md) —
  per-middleware compatibility matrix for the mORMot2 provider

---

## 10. Appendix · staging-folder location

The six staged files described in §3 live at
`/workspaces/horse-crosssocket/mormot2-fork-sync-action/` in this workspace.
That is **staging only** — they are not committed there. Deployment is to
the fork's own checkout (`C:\lang\Repo\mORMot2\` on Windows), as documented
in §3.6 (`INSTRUCTIONS.md`) and reproduced in detail in the staged file
itself.

Once deployed, this workspace's copy can be deleted or retained as a backup.

---

## Appendix · the walker source (verbatim)

`mormot2-fork-sync-action/.sync/walk-uses.sh` (about 155 LOC):

```bash
#!/usr/bin/env bash
# Transitive 'uses' closure walker for mORMot2 subset forks.
#
# Reads a seed file (one mormot.* unit name per line, comments with '#' allowed)
# plus a path to an upstream mORMot2 source tree, and prints the transitive
# closure on stdout as relative paths under src/, sorted, one per line.
#
# The closure walk covers:
#   • Pascal 'uses' clauses — interface and implementation sections both
#   • '{$I path\file.inc}' include directives — needed because mORMot2 splits
#     platform-specific code into sibling .inc files that are not visible from
#     uses clauses alone.
#
# Anything not prefixed with 'mormot.' (RTL, FCL, Windows, Posix, System.*,
# Vcl.*, external libs) is treated as a terminal — the walker doesn't try to
# resolve it. The output therefore contains ONLY mORMot2-internal files.
#
# Exit codes:
#   0 — closure computed, printed to stdout
#   1 — usage error
#   2 — seed unit not found on disk in the upstream tree
#   3 — referenced 'mormot.*' unit could not be resolved to a file
#
# Usage:
#   walk-uses.sh <seed-file> <upstream-mormot2-root>

set -uo pipefail
# NB: 'set -e' deliberately omitted. The BFS uses several grep pipelines whose
# normal "no match" exit code is 1, and we want those to be no-ops rather than
# script failures. Real errors are surfaced via explicit exit calls.

# ... (full body in mormot2-fork-sync-action/.sync/walk-uses.sh) ...
```

The script is small enough to read end-to-end; if you need to modify it
(walker regex changes, additional include-directive forms, etc.) keep the
six semantics rules from §3.3 intact and re-run the dry-run command from §4
to confirm the manifest count and folder breakdown stay sensible.
