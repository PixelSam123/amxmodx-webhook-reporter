# Releasing

Maintainer runbook: how to cut a release and the GitHub settings this
repository expects. User-facing installation instructions live in the
[README](README.md).

## One-time repository setup

Do these once, before the first public release.

### Pre-public checklist

1. Scan for secrets, including history:

   ```bash
   gitleaks git . --no-banner
   gitleaks dir . --no-banner
   ```

2. Confirm the live config is not tracked (only the example should be):

   ```bash
   git ls-files amxmodx/configs
   ```

3. Make the repository public: **Settings -> General -> Danger Zone ->
   Change repository visibility**.

### Code security

**Settings -> Code security**:

- **Dependabot alerts** - enable.
- **Dependabot security updates** - enable. (The `.github/dependabot.yml` file
  only keeps the pinned GitHub Actions up to date.)
- **Secret scanning** - enable.
- **Push protection** - enable. Pushes containing a known secret are then
  rejected.
- **Private vulnerability reporting** - enable. The link in
  [`SECURITY.md`](SECURITY.md) only works when this is on.
- **Code scanning / CodeQL** - not applicable; there is no Pawn analyzer.

If a webhook URL is ever pushed, GitHub blocks the push. If it leaked before
push protection was enabled, delete the webhook in Discord and create a new
one.

### Actions

**Settings -> Actions -> General**:

- **Workflow permissions** -> *Read repository contents and packages
  permissions*. The `release` job requests `contents: write` itself, so the
  repository default can stay read-only.
- **Fork pull request workflows** -> require approval for first-time
  contributors.
- Uncheck **Allow GitHub Actions to create and approve pull requests**.

### Rulesets

**Settings -> Rules -> Rulesets**:

- **`main` branch**: block force pushes and deletions; require the
  `Build (Linux)` and `Build (Windows)` status checks. Requiring a pull request
  is optional for a solo maintainer.
- **`v*` tag**: restrict creations and deletions to maintainers.

### Repository metadata

- Add a description and topics: `amxmodx`, `amxmodx-plugin`, `counter-strike`,
  `cs16`, `discord`, `webhook`, `pawn`.
- Enable **Issues** (and **Discussions** if you want community support).
- **Settings -> General -> Pull Requests** -> enable *Automatically delete head
  branches*.

## Cutting a release

A release is published only for a `v*` tag whose commit has successful Linux
and Windows builds.

1. Bump the version in `amxmodx/scripting/webhook_reporter.sma`:

   ```pawn
   #define VERSION "1.3.0"
   ```

   Update the README if behaviour changed.

2. Commit the bump:

   ```bash
   git commit -am "chore: release v1.3.0"
   ```

3. Create an annotated tag and push both the branch and the tag:

   ```bash
   git tag -a v1.3.0 -m "v1.3.0"
   git push origin main
   git push origin v1.3.0
   ```

4. Watch **Actions -> Build AMXX Plugin**. Both build jobs must pass; the
   `Release` job then publishes a GitHub Release with:

   - `webhook_reporter.amxx`
   - `SHA256SUMS`
   - `webhook_reporter-v1.3.0-source.zip`

5. Verify the release:

   ```bash
   gh release view v1.3.0
   gh release download v1.3.0
   sha256sum -c SHA256SUMS
   ```

   On Windows:

   ```powershell
   Get-FileHash .\webhook_reporter.amxx -Algorithm SHA256
   ```

6. Smoke test on a server: `amxx plugins` should list
   `Discord Webhook Reporter` with the new version.

### Pre-releases

A tag whose name contains a hyphen after the version publishes a GitHub
**pre-release**:

```pawn
#define VERSION "1.4.0-rc1"
```

```bash
git tag -a v1.4.0-rc1 -m "v1.4.0-rc1"
git push origin v1.4.0-rc1
```

The tag must match `VERSION` exactly, including the suffix. The release job
fails if it does not.

### What the workflow enforces

- The tag starts with `v`.
- The tag without the `v` prefix equals `#define VERSION` in the plugin.
- The Linux and Windows builds both succeed.
- Tags containing `-` are published as pre-releases.

Manual runs (`workflow_dispatch`) and pull requests build but never publish.

## Fixing a bad release

- **Build failed**: fix the code, delete the tag locally and remotely, then
  re-tag the fixed commit:

  ```bash
  git tag -d v1.3.0
  git push origin :v1.3.0
  ```

- **Assets are wrong**: re-run the `Release` job from the Actions tab. It
  re-uploads the assets with `--clobber`.
- **Never move a published tag** that points at a good release; cut a new patch
  version instead.

Re-pushing the same tag quickly can cancel the previous run because of the
workflow `concurrency` group.

## Notes

- Actions artifacts expire (about 90 days); GitHub Releases are permanent.
- `SHA256SUMS` covers both the `.amxx` and the source archive.
- The source archive is generated from the tagged commit, which satisfies the
  GPL source-distribution requirement for the compiled plugin.
