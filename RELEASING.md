# Releasing Kyde

Releases are automated by [release-please](https://github.com/googleapis/release-please)
(`.github/workflows/release.yml`). You don't bump versions, edit the changelog, or
push tags by hand — you just write good commit messages and merge a PR.

Kyde follows [Semantic Versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`.

## How it works

1. You merge normal PRs into `main` using **Conventional Commits** (below).
2. release-please watches `main` and keeps a standing **"release PR"** open that
   bumps `Cargo.toml` + `Cargo.lock`, updates `CHANGELOG.md`, and computes the next
   version from the commits since the last release.
3. When you're ready to ship, **merge the release PR**. release-please then creates
   the `vX.Y.Z` git tag and the GitHub Release.
4. In the same workflow run, the `build` job packages the three platform artifacts
   (macOS `.app` zip, Linux AppImage, Windows `.exe` zip) and attaches them to the
   release.

That's it. Cutting a release = merging one PR.

## Conventional Commits (this is the only discipline required)

The commit messages on `main` decide the version bump:

| Commit prefix | Bump | Example |
|---|---|---|
| `fix:` | PATCH | `fix: stop crash on empty diff` |
| `feat:` | MINOR | `feat: add Go language pack` |
| `feat!:` / `fix!:` or a `BREAKING CHANGE:` footer | MAJOR | `feat!: change keymap.json schema` |
| `chore:`, `docs:`, `refactor:`, `test:`, `ci:` | none | housekeeping, no release |

A breaking change is anything that breaks a config format (theme/keymap/plugins/
projects JSON), the `ky` CLI, or removes a feature. While Kyde is `0.x` SemVer makes
no compatibility promise; the practical convention is `0.MINOR` may break and
`0.MINOR.PATCH` does not. Save `1.0.0` for when the config formats and the
commit/diff workflow are stable enough to promise it.

The version lives in exactly one place release-please owns: `Cargo.toml` `version`
(mirrored into the binary via `CARGO_PKG_VERSION`, the macOS Info.plist, and the
Windows `.exe` metadata). The git tag always matches it — release-please guarantees
the lockstep that used to be manual.

## After a release

Don't move or delete a published tag — they're immutable once people may have
pulled them. A broken release is fixed by landing a `fix:` commit and shipping the
next PATCH (release-please will offer it in the next release PR).

## Manual fallback

If you ever need to release without release-please (e.g. the action is down), note
that pushing a tag by hand will **not** trigger the build — the `build` job in
`release.yml` is gated on release-please's `release_created` output, and tags created
with the default token don't fire it. So a manual release means doing the packaging
yourself too: bump `Cargo.toml`, update `CHANGELOG.md`, push a `vX.Y.Z` tag and create
the GitHub Release yourself, then run the `build` matrix locally (the bundle scripts:
`scripts/bundle-macos.sh`, `scripts/bundle-linux.sh`, and a `cargo build --release` on
Windows) and `gh release upload` each artifact. The automated path is strongly
preferred.
