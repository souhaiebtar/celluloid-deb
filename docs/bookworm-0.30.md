# Celluloid 0.30 on Debian 12 (bookworm)

Short answer: **not shipped, and not reasonably buildable.** The chain there is
eight packages, starting at glib and running through fontconfig and freetype —
not the two that trixie needs.

Every claim below was measured in a `debian:12` container, not estimated.

## The requirement chain

Celluloid 0.30 -> libadwaita 1.8 -> GTK 4.20 -> {glib 2.82, pango 1.56,
harfbuzz 8.4, cairo 1.18} -> {fontconfig 2.15, freetype 2.13}.

`bookworm-backports` carries none of glib, pango, cairo or harfbuzz, so it does
not shorten the chain.

Celluloid also cannot be patched around it: its use of `AdwShortcutsDialog`
means libadwaita 1.8 is genuinely required, and libadwaita 1.8 has a hard
compile-time `#error` below GTK 4.19.4.

## What was verified, link by link

| # | Package | bookworm has | needed | Result |
|---|---|---|---|---|
| 1 | glib 2.82.5 | 2.74.6 | 2.82 | **builds and installs** |
| 2 | harfbuzz 8.4.0 | 6.0.0 | 8.4.0 | **builds** |
| 3 | cairo 1.18.4 | 1.16.0 | 1.18.2 | **builds** (against bookworm's freetype 2.12) |
| 4 | pango 1.56.3 | 1.50.12 | 1.56 | **fails** — see below |
| 5 | fontconfig 2.15 | 2.14.1 | 2.15 | not attempted (blocker for 4) |
| 6 | freetype 2.13 | 2.12.1 | 2.13 | not needed (cairo built without it) |
| 7 | GTK 4.20.4 | 4.8.3 | 4.20 | blocked by 4 |
| 8 | libadwaita 1.8.8 | 1.2.2 | 1.8 | blocked by 7 |

## Why pango is the hard stop

pango 1.56 requires `fontconfig >= 2.15.0`. Lowering the declared floor is not
enough, because the dependency is a real API:

```
pango/pangofc-fontmap.c:1110:38: error:
  'FC_FONT_WRAPPER' undeclared (first use in this function)
```

`FC_FONT_WRAPPER` exists in fontconfig 2.15 (trixie ships 2.15.0) and does not
exist in bookworm's 2.14.1. So fontconfig must be backported as well, and pango
cannot be built before it.

GTK cannot avoid pango's fontconfig path either: `pangoft2` is a hard
requirement whenever X11 or Wayland is enabled.

## Why it is not shipped

- **Eight forked packages**, versus two for trixie.
- **glib is the foundation of the system.** A private-prefix glib works for a
  self-contained application, but anything loading both copies (plugins,
  introspection, theme engines) risks subtle breakage. Shadowing GTK is a far
  smaller surface than shadowing glib.
- **fontconfig and freetype are core text stack.** Backporting them under
  `/opt` while other applications use the system copies invites font
  enumeration and fontconfig cache inconsistencies that are painful to debug.
- **Celluloid 0.27 already works on bookworm** with no backports at all.
- **Debian itself does not attempt this** for the same reason.

The honest framing: eight packages, two of which are glib and fontconfig,
maintained for the life of Debian 12. That is a project in its own right.

## What this repo does instead

`build.sh` resolves bookworm to **0.27**, which builds against bookworm's own
libraries with no backports. It is verified working and published as a normal
release artifact.

## If it is ever attempted

Order matters, and each step needs the previous one installed into a shared
prefix:

```
glib 2.82 -> harfbuzz 8.4 -> fontconfig 2.15 -> freetype 2.13
          -> cairo 1.18 -> pango 1.56 -> GTK 4.20 -> libadwaita 1.8
```

All of 1-3 and 6-7 above are known to build. The unknown work is fontconfig and
freetype, which have their own dependency chains not yet explored.
