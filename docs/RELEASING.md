# Releasing

1. Update `VERSION` and `CHANGELOG.md`, commit.
2. Check the code:

   ```bash
   bash tests/run.sh
   bash tools/lint.sh
   ```

3. Build and publish:

   ```bash
   export GITHUB_TOKEN=...                 # repo scope
   bash tools/release.sh                   # creates a draft release v<VERSION> with the files
   bash tools/release.sh --publish         # or publish it right away
   ```

   `tools/build.sh` writes three files to `dist/`:

   | File | Purpose |
   |---|---|
   | `spartan_installer.sh` | Bootstrap, pinned to this release's tag and the bundle's SHA-256 |
   | `spartan_installer.bundle.sh` | The installer (all modules in one file) |
   | `spartan_installer.bundle.sh.sha256` | Checksum, used by unpinned bootstraps |

4. Test the published release on a fresh VM with the one-liner from the README.

## How the files fit together

`bash -c "$(curl ...)"` passes the downloaded script to bash as one argument, and Linux limits one argument to 128 KiB. The full installer is larger, so the release splits it: the small bootstrap is what the one-liner downloads, and it fetches the bundle from **its own tag** (`releases/download/v2.0.0/...`, not `latest`) and checks the checksum written into it at build time. A new release can therefore never break a bootstrap that is already in someone's terminal or script.

The bootstrap passes its arguments through unchanged, in all the forms that are in use:

```bash
bash -c "$(curl -fsSL .../spartan_installer.sh)" -- --non-interactive --update    # Spartan's auto-updater
bash -c "$(curl -fsSL .../spartan_installer.sh) -- --non-interactive --install"   # 1.x README form
curl -fsSL .../spartan_installer.sh | sudo bash -s -- --install                   # stdin is re-attached to the terminal
sudo bash spartan_installer.sh --install
```

For a VM test before publishing, copy `dist/spartan_installer.bundle.sh` to the server and run it directly (`sudo bash spartan_installer.bundle.sh`), or point the bootstrap at it with `SPARTAN_BUNDLE_FILE=/root/spartan_installer.bundle.sh`.

## Moving to the main repository

Spartan's automatic updater downloads `https://github.com/dezerx-spartan/Spartan-Installer/releases/latest/download/spartan_installer.sh`. To ship 2.x to existing servers, publish the release in that repository (build with `bash tools/build.sh --repo dezerx-spartan/SPARTAN-INSTALLER`), or change the URL in `AutoUpdaterCommand.php`.

1.x bootstraps that are already downloaded fetch `spartan_installer.part2.sh` from the latest release and compare it with a checksum pinned in 1.x; they stop with a checksum error as soon as any newer release exists. That is 1.x behaviour and cannot be fixed from a new release; re-downloading the one-liner is enough.
