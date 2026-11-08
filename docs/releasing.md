# Making a release


1. Set the new version in `windows/Directory.Build.props` (`<Version>`) and `macos/Sources/SteadyVolumeCore/Paths.swift` (`version`), commit and push.
2. Tag that commit and push the tag:

   ```bash
   git tag v1.0.1
   ```

   ```bash
   git push origin v1.0.1
   ```

3. CI builds and tests both platforms. The `release` job then checks that the tag matches both versions, zips both builds (`steadyvolume-1.0.1-windows-x64.zip`, `steadyvolume-1.0.1-macos-universal.zip`) with a `SHA256SUMS.txt`, and creates a **draft** GitHub release with generated notes. A tag with a suffix, such as `v1.1.0-beta.1`, makes a pre-release.
4. Open the draft under Releases, check it, and press **Publish release**.

## Download channels

| Channel | What it is | Link |
|---|---|---|
| **Release** | A tagged version, reviewed and published by hand. Use this normally. | [Latest release](https://github.com/weehong-1/steadylock/releases/latest) |
| **Development build** | Whatever is on `main` right now, built by CI on every push. Untested beyond the unit tests. | [Windows](https://nightly.link/weehong-1/steadylock/workflows/build/main/steadyvolume-windows-x64.zip) · [macOS](https://nightly.link/weehong-1/steadylock/workflows/build/main/steadyvolume-macos-universal.zip) ([all files](https://nightly.link/weehong-1/steadylock/workflows/build/main)) |

Development builds come through [nightly.link](https://nightly.link), a third-party service that serves the latest successful CI artifacts without a GitHub login. GitHub keeps artifacts for 90 days, so the links stop working if nothing is pushed to `main` for that long.
