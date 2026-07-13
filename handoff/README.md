# Compiler-team handoff — reporter artifacts CI

Drop the workflow file into `.github/workflows/reporter-artifacts.yml` on the
compiler repo. That's it — nothing else on your side.

## What the workflow does

On every push to a `v*` release tag:

1. Spins up MySQL as a service container.
2. Installs clean-node-server (latest) and mysql-client.
3. Installs the freshly-built `cln` binary from this release into PATH.
4. Downloads `cln-repro run` from the clean-errors repo.
5. Lists every open GitHub issue labelled `reporter-artifact` on this repo.
6. For each issue: downloads the attached tarball, unpacks it, boots
   clean-node-server against the tarball's WASM (built by the reporter
   with the version they were on when it failed) — **wait, correction**:
   the tarball ships the WASM but the CI job's purpose is to test the
   *new compiler*. See "Two-mode replay" below.

## Two-mode replay — important

The naive replay tests "does the reporter's WASM work today?" That's not
what we want. What we want is "does the current compiler produce a WASM
that passes the reporter's assertions?"

So the CI job actually:

1. Downloads the tarball → gets `source/`, `fixture/`, `run/`.
2. Compiles `source/` with **the current compiler** (this release).
3. Replaces the tarball's `wasm/errors.wasm` with the freshly-compiled one.
4. Runs `run.sh` — same DB fixture, same URL, same expected matches, but
   against the new WASM.

This means: fix the codegen bug, push a release, CI rebuilds every
reporter's source with the new compiler, runs their assertions, blocks
the release if anything is still red.

**TODO in this handoff:** the current workflow YAML doesn't yet do the
"recompile from source, replace WASM" step. See section below for the
patch that adds it. Included as-is so you can review the base flow first.

## Two-mode replay patch (add before `- name: replay each tarball`)

```yaml
      - name: patch tarball replay to use current compiler
        run: |
          # Wrapper around cln-repro that recompiles source/ with the just-built
          # cln, replaces wasm/errors.wasm, then invokes the tarball's run.sh.
          cat > /usr/local/bin/cln-repro-recompile-and-run <<'WRAPPER'
          #!/bin/bash
          set -euo pipefail
          TARBALL="$1"
          WORK=$(mktemp -d)
          tar xzf "$TARBALL" -C "$WORK"
          # Compile using the current cln binary
          ( cd "$WORK/source" && cln compile --plugins -o "$WORK/wasm/errors.wasm" main.cln )
          # Now replay
          cd "$WORK" && bash run.sh
          WRAPPER
          chmod +x /usr/local/bin/cln-repro-recompile-and-run
```

Then in the "replay each tarball" step, replace `cln-repro run "$ISSUE_URL"`
with a download-then-`cln-repro-recompile-and-run` sequence. Left as a
minor refactor.

## Secrets required

None beyond `GITHUB_TOKEN` (auto-provided). The workflow reads the current
repo's issues (public) and writes comments (uses default token).

## Cost estimate

- One MySQL service container per run: ~200 MB, 30s startup.
- One replay per open reporter-artifact issue: ~15s each (compile + boot +
  curl + diff).
- Expected max: 10-30 open reporter-artifact issues at any given time
  based on today's queue load, i.e. 5-10 minutes of runner time per
  release. Well within GitHub Actions free tier.

## Rollout order

1. **Merge the workflow file, leave it disabled** (via workflow_dispatch
   only). Test manually against a known-red tarball on `master`.
2. **Enable on release tags.** Any push to `v*` runs the replay.
3. **Block release** by making the workflow required in branch protection
   rules on the release branch.

Steps 1 and 2 can happen the same day. Step 3 waits until we have
5-10 tarballs in flight so we know the workflow is stable.

## Auto-resolution (later, once this is stable)

When a tarball transitions FAIL → PASS between releases, the workflow
posts a comment; but it does NOT close the issue. Reporter's supervisor
(polling this repo's release feed) is what decides "the reporter's
box also verified green → close the ticket." Two independent signals,
one closure. See closed-loop design in clean-errors repo,
tools/cln-repro/README.md.
