# Releasing

The GitHub release has to exist *before* the pub release, because the manifest
that pub ships records the hashes of the release artifacts.

1. Bump `version:` in `pubspec.yaml` **and** `version` in `rust/Cargo.toml` —
   they must match, and a test asserts it. Update `CHANGELOG.md`.
2. Commit, then tag and push:
   ```sh
   git tag v0.2.0 && git push origin main v0.2.0
   ```
3. Wait for the **Release** workflow. It cross-compiles the `cdylib` for all 12
   targets in `rust/rust-toolchain.toml` and attaches them, plus `SHA256SUMS`,
   to the GitHub release.
4. Point the build hook at that release:
   ```sh
   dart run tool/update_prebuilt.dart
   ```
   This rewrites `hook/prebuilt.json` from `SHA256SUMS`. It fails if any of the
   12 artifacts is missing.
5. Commit `hook/prebuilt.json` and publish:
   ```sh
   dart pub publish
   ```

If step 4 is skipped, nothing breaks: the manifest's `version` will not match
`pubspec.yaml`, and the build hook compiles from source as it always did. That
is also the fallback whenever a download fails, a target is not covered, or the
consumer's deployment target is older than the artifacts were built for.

## Deployment targets

The values baked into the artifacts live in `.github/workflows/release.yml` and
are mirrored in `tool/update_prebuilt.dart`. Changing one means changing both.

| | Artifacts built for |
|---|---|
| iOS | 12.0 |
| macOS | 10.14 |
| Android | API 21 |
| Linux | glibc of `ubuntu-22.04` (2.35) |
