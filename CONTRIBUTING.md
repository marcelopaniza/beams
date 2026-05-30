# Contributing to buses

Thanks for the interest. This project is small and the contribution bar is simple: **the test suite stays green and the README still matches reality.**

## Dev setup

Clone the repo and run the smoke tests:

```
git clone https://github.com/marcelopaniza/buses
cd buses
bash tests/run-all.sh        # 9 rounds, ~135 s
```

Tests run against a temporary share directory in `/tmp` and clean up after themselves. You'll need: `bash` 4.0+, `jq`, `openssl` 1.1.1+, `find`, `awk`, `sed`.

Run a subset:

```
bash tests/run-all.sh 3 9    # only rounds 3 and 9
```

## Commit style

Subject:

- `vX.Y.Z: short summary` for release commits.
- `<area>: short description` for non-release commits (e.g. `tests/round-3: …`, `README: …`, `lib/check.sh: …`).

See `git log` for the established pattern.

Body:

- Short opening paragraph framing the change.
- Sections like `### Added`, `### Fixed`, `### Security`, `### Code quality`, `### Tests`, `### README` — `-` bullets under each.
- Lead bullets with the **why**, not the **what**. The diff shows the what. Readers in six months will only have the body.
- No `Co-Authored-By:` footer — the project's history doesn't use one.

## PR expectations

- Tests pass: `bash tests/run-all.sh` exits 0.
- New behaviour gets new test coverage. Either a new section in an existing round (`tests/round-N.sh`) or a new round.
- For non-trivial changes, run the project's [`/code-review`](https://docs.claude.com/en/docs/claude-code/skills) and [`/security-review`](https://docs.claude.com/en/docs/claude-code/skills) skills against your branch before submitting. The recent v0.7.0/v0.7.1 commits set the bar for what that produces.
- README + skill `description:` fields stay in sync with what the code actually does. The cross-CLI section is especially sensitive to over-claiming — see the "Auto-delivery matrix" for the canonical framing.
- For security-sensitive changes (anything touching `lib/common.sh`, `lib/check.sh`, the wire format, identity resolution, the `escape_for_hook` family, or `bin/buses{,-wrap}`), include a one-paragraph threat-model note in the commit body explaining what the change preserves and what it would weaken.

## Reporting bugs / requesting features

GitHub issues. For security vulnerabilities, see `SECURITY.md` — don't open a public issue for those.

## Re-rendering the hero image

If you're touching `assets/hero.html`, re-render `assets/hero.png` before committing so the README image stays in sync with the source:

```
google-chrome --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1600,800 --default-background-color=00000000 \
  --screenshot="$PWD/assets/hero.png" \
  "file://$PWD/assets/hero.html"
```

Commit both files (source + rendered PNG). The PNG is small (~500 KB).
