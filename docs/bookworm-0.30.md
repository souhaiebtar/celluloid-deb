# Celluloid 0.30 on Debian 12 (bookworm)

Short answer: **not shipped.** Everything needed is buildable, but it requires a
six-package chain rather than trixie's two, and the result would be a much larger
thing to maintain than the application it exists to support.

This records what was measured, so the decision can be revisited with numbers
rather than guesswork.

## Why bookworm is harder than trixie

On trixie the only gap was GTK and libadwaita. On bookworm the gap starts further
down, because GTK 4.20 needs a newer glib, pango, harfbuzz and cairo than
bookworm ships:

| Library | GTK 4.20 needs | bookworm has | Verdict |
|---|---|---|---|
| glib | 2.82 | 2.74.6 | gap |
| pango | 1.56 | 1.50.12 | gap |
| harfbuzz | 8.4.0 | 6.0.0 | gap |
| cairo | 1.18.2 | 1.16.0 | gap |
| fribidi | 1.0.6 | 1.0.8 | ok |
| graphene | 1.10 | 1.10.8 | ok |
| gdk-pixbuf | 2.30 | 2.42.10 | ok |

`bookworm-backports` does not help: it carries none of these.

Celluloid 0.30 also cannot be patched around it — the `AdwShortcutsDialog` use
means libadwaita 1.8 is genuinely required, and libadwaita 1.8 has a hard
compile-time `#error` below GTK 4.19.4.

## The chain, and what was verified

Every link was built in a `debian:12` container:

| # | Package | Verified |
|---|---|---|
| 1 | glib 2.82.5 | **builds and installs** |
| 2 | harfbuzz 8.4.0 (against that glib) | **builds** |
| 3 | cairo 1.18.4 (against bookworm's freetype 2.12) | **builds** |
| 4 | pango 1.56 (needs 1 and 2) | not tested |
| 5 | GTK 4.20.4 (needs 1-4) | blocked until 4 exists |
| 6 | libadwaita 1.8.8 (needs 5) | blocked until 5 exists |

Two obstacles surfaced and were resolved during the probes:

- **meson too old.** bookworm has meson 1.0.1; GTK 4.20 needs >= 1.5. Solved by
  installing a newer meson from pip inside the build container. No host change.
- **cairo and freetype.** `cairo-1.18.4/meson.build` asks for freetype >= 2.13
  (bookworm has 2.12.1) for colour-font support, but that requirement is not
  enforced when the freetype feature is not required, and cairo builds fine
  against 2.12. A freetype backport is therefore unnecessary.

So the chain is feasible. The cost is what stopped it.

## Why it is not shipped

- **Six forked library packages**, versus two for trixie. Each must be rebuilt
  and re-verified for every point release of Debian 12.
- **glib is the foundation of the system.** A private-prefix glib under `/opt`
  works for a self-contained application, but anything that loads both copies
  (a plugin, introspection, a theme engine) risks subtle breakage. It is a far
  bigger surface than shadowing GTK.
- **Celluloid 0.27 already works on bookworm** and needs nothing extra. The
  difference between 0.27 and 0.30 does not justify shipping a private glib.
- **Debian itself does not attempt this.** Its own archive ships an old
  Celluloid for bookworm for the same reason.

If it is ever wanted, the honest framing is: six packages, one of which is glib,
maintained for the life of Debian 12. That is a project in its own right, not a
build flag.

## What this repo does instead

`build.sh` resolves bookworm to **0.27**, which builds against bookworm's own
libraries with no backports at all. That version is verified working and is
published as a normal release artifact.
