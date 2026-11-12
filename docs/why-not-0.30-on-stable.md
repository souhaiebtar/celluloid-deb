# Why Celluloid 0.30 is not packaged for Debian 12 and 13

This records the constraint and the experiments behind it, so the decision is not
re-litigated from scratch and so nobody assumes the version split is arbitrary.

## The requirement chain

Celluloid 0.30 declares, in `src/meson.build`:

```
dependency('gtk4', version: '>=4.16.0')
dependency('libadwaita-1', version: '>= 1.8.0')
dependency('mpv', version: '>= 1.107')
```

libadwaita 1.8 in turn requires **GTK >= 4.19.4** and **GLib >= 2.80**, and it is
not merely a version string: `src/adwaita.h` contains a hard compile-time guard.

```
#if !GTK_CHECK_VERSION(4, 19, 4)
# error "libadwaita requires gtk4 >= 4.19.4"
#endif
```

Debian 13 (trixie) ships GTK **4.18.6**, so libadwaita 1.8 cannot be built there.
Debian 12 (bookworm) ships GTK 4.8.3, far below either.

## Measured evidence

| Experiment | Result |
|---|---|
| Celluloid 0.30 vs trixie (GTK 4.18.6, adw 1.7.6), floor lowered to 1.7.0 | Fails to compile |
| libadwaita 1.8.8 vs trixie GTK 4.18.6, floor lowered to 4.18.0 | Fails on the `#error` guard |
| libadwaita 1.8.8 vs trixie with the guard removed | Not a fix; the guard reflects real API use |

The Celluloid failure is genuine API dependence, not an over-strict version
check. In `celluloid-shortcuts-dialog.c`:

```c
#define CELLULOID_SHORTCUTS_DIALOG ADW_SHORTCUTS_DIALOG
...
celluloid_shortcuts_dialog_init(CELLULOID_SHORTCUTS_DIALOG(result));
```

`AdwShortcutsDialog` only became a real type in libadwaita 1.8. On 1.7 the macro
expands to something that is not a type, so the build breaks. Celluloid 0.30
genuinely needs libadwaita 1.8.

## The two possible routes to 0.30 on trixie

Both are substantial, and neither is a packaging change:

1. **Backport GTK >= 4.19.4, then libadwaita 1.8, then build Celluloid 0.30.**
   Measured feasible: see "Can GTK be backported?" below.

2. **Patch Celluloid 0.30** to stop using the 1.8-only APIs. The known break is
   `AdwShortcutsDialog`; there may be others, and each is a behavioural change
   upstream did not make.

Option 1 is the only one that produces a genuine 0.30, since option 2 ships a
modified program that is no longer 0.30.

## Can GTK 4.19.4 be built for trixie and used with Celluloid 0.30? Yes

This was tested end to end inside a `debian:13` container rather than estimated:

| Step | Result |
|---|---|
| GTK 4.19.4 configure on trixie | OK (needs glib >= 2.82; trixie has 2.84) |
| GTK 4.19.4 compile | **OK** |
| GTK 4.19.4 install into `/opt/gtk419` | **OK** (`pkg-config` reports 4.19.4) |
| libadwaita 1.8.8 configure against that GTK | **OK** |
| libadwaita 1.8.8 compile | **OK** |

GTK 4.20.4 (the matching stable release) also compiles on trixie. So a genuine
Celluloid 0.30 on Debian 13 is technically achievable.

### Obstacles found, and their severity

| Obstacle | Status |
|---|---|
| GTK 4.19.4/4.20 needs **wayland >= 1.24**; trixie has 1.23.1 | Must disable the Wayland backend, or backport Wayland too |
| `librsvg2`, `libdrm`, `python3-jinja2`, `glib >= 2.82` | Fine: all satisfied by trixie |
| libadwaita 1.8 has a hard `#error` below GTK 4.19.4 | Resolved by building the newer GTK, not by patching the guard |

The Wayland point is the significant one. Building GTK without its Wayland
backend means the resulting Celluloid has no native Wayland support: on a
Wayland desktop it runs through XWayland. For a video player that is a real
functional regression, and it is not something a version string can hide.

## Cost of doing it properly

A GTK backport is not a rebuild with a flag flipped:

- It must install into a private prefix (`/opt/gtk419`) **or** replace the
  system GTK. Replacing system GTK breaks every other GTK4 application on the
  machine if anything goes wrong; a private prefix means Celluloid has to be
  built and wrapped to find it, and theme and portal integration get fragile.
- Wayland support is lost unless Wayland itself is backported as well.
- libadwaita must be backported into the same private prefix.
- Two extra forked packages (GTK, libadwaita) must be maintained for the life of
  Debian 13.

Put plainly: a user who installs this to get Celluloid 0.30 ends up with a system
where GTK is no longer what Debian shipped — a far larger change than the
application package. That is the reason Debian itself ships 0.28 in trixie
rather than doing this.

## Current state

`build.sh` resolves per suite, so each Debian release gets the newest Celluloid
that genuinely builds on it:

| Suite | Celluloid | Because |
|---|---|---|
| bookworm (12) | 0.27 | needs GTK 4.6.1 / adw 1.2; 0.28+ needs GTK 4.16 |
| trixie (13) | 0.29 | needs GTK 4.16 / adw 1.6; 0.30 needs adw 1.8 -> GTK 4.19.4 |
| sid | 0.30 | GTK 4.24 / adw 1.10 satisfy it |

This matches Debian's own archive, which ships 0.28 in trixie and 0.29 in sid.
