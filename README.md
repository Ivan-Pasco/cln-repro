# cln-repro — reproduction bundler for the closed-loop bug workflow

Captures a failing HTTP request against a Clean Language app, bundles the exact
runnable artifact, and files it as a GitHub issue on the fixer's repo. Fixer
CI runs the bundle as a replay test; when the bundle starts passing on a
release candidate, the ticket auto-resolves.

The tarball format is deterministic and self-contained: anyone with
`bash`, `mysql`, `clean-node-server`, and a `cln` compiler can unpack and
`bash run.sh` to reproduce the exact failure.

## Commands

- `cln-repro capture` — bundle a failing request into a tarball and file it as a GitHub issue
- `cln-repro run <issue-url-or-tarball>` — replay a tarball locally, print pass/fail

## Layout inside a tarball

```
<fingerprint>.tar.gz
├── manifest.json           # spec below
├── source/                 # copy of the .cln source tree
├── wasm/errors.wasm        # exact compiled binary
├── fixture/schema.sql      # DDL
├── fixture/data.sql        # minimal INSERT set — only rows the query touched
├── run/request.http        # method + URL + headers + body
├── run/expected.http       # expected response
├── run/actual.http         # observed response at capture time
├── env/versions.txt        # cln, node-server, frame.* pins
└── run.sh                  # one-command replay
```

See `spec/manifest.schema.json` for the manifest shape.

## Fingerprint

`sha256(component + url + method + expected_status + actual_status +
sorted(expected_matches) + sorted(actual_matches) + versions)`

Deliberately excludes WASM bytes and full response bodies — those change on
every build. Same behavioral gap = same fingerprint, even across releases.
