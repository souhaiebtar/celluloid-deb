# Celluloid — Debian package builder

Builds installable `.deb` packages for [Celluloid](https://github.com/celluloid-player/celluloid)
(the GTK4 frontend for mpv) from official upstream release tarballs, for Debian
12, 13 and unstable.

Nothing here is an official Debian package. These are local rebuilds of the
upstream releases, distributed under the same GPL-3+ terms as Celluloid itself.

## Why versions differ per release

Celluloid raises its GTK and libadwaita requirements every few releases, and
Debian releases freeze their libraries for years. That combination means the
newest upstream version is often *not buildable* on an older Debian. The builder
resolves this rather than hardcoding it:

| Suite | GTK4 | libadwaita | libmpv | Newest Celluloid that builds |
|---|---|---|---|---|
| bookworm (12) | 4.8.3 | 1.2.2 | 0.32 | **0.27** |
| trixie (13) | 4.18.6 | 1.7.6 | 0.40 | **0.29** (or **0.30** with backports) |
| sid | 4.24 | 1.10.0 | 0.42 | **0.30** |

Celluloid 0.30 requires `libadwaita >= 1.8.0`, which Debian 13 does not have.
That is not a packaging choice — it is a hard dependency, and libadwaita 1.8
itself needs GTK >= 4.19.4. Debian 13 therefore gets 0.29 by default, which is
also what Debian's own archive ships there.

**To get genuine 0.30 on Debian 13**, build the private-prefix GTK 4.20 and
libadwaita 1.8 backports first:

```bash
./build-backports.sh     # ~10 min the first time
./build.sh trixie        # now resolves to 0.30
```

They install under `/opt/gtk420`, so the system GTK is untouched and other
applications keep using 4.18. See [docs/backport-design.md](docs/backport-design.md)
for the measurements, the design, and the caveats.

The resolution is automatic: `build.sh` reads each upstream release's declared
dependency floors from its `meson.build`, compares them against the target
suite's library versions, and picks the newest release that fits. If the
container build still rejects a version, it steps back one release and retries.

## Requirements

- `podman` (preferred, rootless) or `docker`
- `curl`, `tar`, `gpg`, `python3` ≥ 3.11, `dpkg`

No root is needed on the host: all building happens inside containers.

## Usage

```bash
./build.sh                      # build every suite
./build.sh trixie               # build just Debian 13
./build.sh --list               # show the resolved plan, build nothing
./build.sh --latest sid         # force the newest release on sid
./build.sh --version 0.30 sid   # build one exact version
./build.sh --verbose trixie     # stream the container build log
./build.sh --rebuild-image      # refresh the cached dependency images
./build.sh --no-cache trixie    # bypass the image cache entirely
```

Packages land in `dist/<suite>/`.

## Build caching

Installing the build dependencies costs about **2.5 minutes per suite**, which
dominated every build. The first run now bakes them into an image, and later
runs reuse it:

| Run | Time (trixie) |
|---|---|
| First run (builds the image) | ~263s |
| Subsequent runs (cached) | **~26s** |
| `--no-cache` | ~164s |

The cached image is tagged with a hash of its recipe — base image, dependency
list and Dockerfile template — so changing any of them produces a new tag and
the stale image is ignored. Nothing needs clearing by hand.

```bash
podman images | grep celluloid-build      # the cached images
./build.sh --rebuild-image                # force a refresh
```

If the image cannot be built, the build falls back to installing dependencies
inside a plain container: slower, but it still works.

## Installing the result

Built packages are published to the repository's
[releases page](https://github.com/souhaiebtar/celluloid-deb/releases), so you
can download them without building anything:

- **A `v*` tag push** produces a normal release for that tag.
- **A push to `main`**, a weekly schedule, or a manual run produces a rolling
  **`nightly`** pre-release, replaced on each run so stale assets do not
  accumulate.
- **Pull requests** build but never publish.

Or build locally and install from `dist/`:

```bash
sudo apt install ./dist/trixie/celluloid_0.29-1~trixie_amd64.deb
```

`apt` (not `dpkg -i`) is deliberate: it resolves the runtime dependencies the
package declares. The `-dbgsym` package is not built by default; set
`WITH_DBGSYM=1` if you want debug symbols.

## How a build works

1. **Resolve** — pick the newest upstream release buildable on the suite.
2. **Fetch** — download the release tarball and its detached GPG signature.
3. **Verify** — check the signature against the upstream signing key. A bad or
   missing signature aborts the build unless `--no-verify` is passed.
4. **Package** — generate a `debian/` tree matching that version and suite.
5. **Build** — run `dpkg-buildpackage` inside a container image for the target
   suite, so the binaries link against exactly the libraries that release
   ships. The image already contains the build dependencies (see above).
6. **Collect** — copy the resulting `.deb` into `dist/<suite>/`.

Generated version strings use the form `0.30-1~sid`. The `~suite` suffix sorts
*below* a plain `0.30-1`, so a real Debian archive upload of the same upstream
version always takes precedence over a locally built package.

## Layout

```
build.sh              entrypoint
build-backports.sh    builds GTK 4.20 + libadwaita 1.8 for Debian 13
suites.toml           target suites and their library versions
backports.toml        backport sources, versions and prefixes
lib/common.sh         logging and small helpers
lib/resolve.sh        picks the version per suite
lib/source.sh         download + GPG verification
lib/packaging.sh      generates the debian/ tree
lib/container.sh      runs dpkg-buildpackage in a container
lib/parse-meson.py    extracts dependency floors from meson.build
packaging/            templates for debian/control, rules, changelog, ...
packaging/backport/   templates for the private-prefix library packages
docs/                 why versions differ, and the backport design
tests/run.sh          fast checks (no container needed)
tests/verify-package.sh  validates a built .deb
dist/<suite>/         built packages
dist/backports/       built GTK/libadwaita backports
build/                scratch space (safe to delete)
```

## Caveats worth knowing

- **These are rebuilds, not official packages.** If Debian ships Celluloid 0.28
  in trixie and you install `0.29-1~trixie` from here, `apt upgrade` will not
  replace it with an older archive version later.
- **Library versions are tracked in `suites.toml`.** If Debian point-releases
  bump a library, refresh that table; `--list` will otherwise show stale
  ceilings. The container build remains the final authority either way.
- **Only the host architecture is built.** Cross-building for `arm64` from an
  `amd64` host is not wired up.
- **Signature verification trusts the key's user ID**, not a web of trust. The
  expected fingerprint is pinned in `build.sh` (`UPSTREAM_FINGERPRINT`) and
  checked, which is the part that actually matters.
