# Backporting GTK 4.20 + libadwaita 1.8 for Debian 13 (trixie)

Goal: ship genuine Celluloid 0.30 on Debian 13, with **native Wayland**, without
touching the system GTK.

This document records what was measured before writing the packaging, so the
design rests on evidence rather than assumption.

## Why three backports and not two

Celluloid 0.30 -> libadwaita >= 1.8 -> GTK >= 4.19.4 -> wayland >= 1.24.

The Wayland requirement is not conservative. Building GTK 4.20 against trixie's
wayland 1.23.1 fails on a genuinely new enum:

```
gdk/wayland/gdkseat-wayland.c:1500:18: error:
  'WL_KEYBOARD_KEY_STATE_REPEATED' undeclared (first use in this function)
```

So getting native Wayland means shipping Wayland 1.24 too. The alternative —
GTK with `-Dwayland-backend=false` — compiles but loses native Wayland, leaving
Celluloid on XWayland. That was rejected.

## Measured build results (all in debian:13 containers)

| Component | Result |
|---|---|
| wayland 1.24.0 | configures, builds, installs to a prefix |
| GTK 4.19.4 | configures, builds, installs |
| GTK 4.20.4 (X11 only) | builds |
| GTK 4.20.4 with wayland 1.24 | builds (requires the wayland backport) |
| libadwaita 1.8.8 against backported GTK 4.19.4 | configures and builds |

Version floors, all satisfied by trixie except where noted:

| Requirement | Needs | trixie has |
|---|---|---|
| wayland | 1.24.0 | 1.23.1 ❌ (backported) |
| wayland-protocols | 1.44 | 1.44 ✅ |
| glib | 2.82 | 2.84 ✅ |
| pango | 1.56 | 1.56.3 ✅ |
| harfbuzz | 8.4 | 10.2 ✅ |
| cairo | 1.18.2 | 1.18.4 ✅ |
| graphene | 1.10 | 1.10.8 ✅ |
| fribidi | 1.0.6 | 1.0.16 ✅ |
| libffi (wayland) | any | 3.4.8 ✅ |

## Design constraints that shape the packaging

### 1. System GTK must not be replaced

Replacing `/usr/lib/x86_64-linux-gnu/libgtk-4.so.1` would affect every GTK4
application on the machine. Everything is installed under `/opt/gtk420` instead,
with a `pkg-config` fragment so dependents build against it.

### 2. GSettings schemas collide

GTK 4.20 ships the same schema IDs and paths as the system 4.18, verified:

```
4.20 : <schema id='org.gtk.gtk4.Settings.FileChooser' path='/org/gtk/gtk4/settings/file-chooser/'>
4.18 : <schema id='org.gtk.gtk4.Settings.FileChooser' path='/org/gtk/gtk4/settings/file-chooser/'>
```

Installing both into the same schema directory makes `glib-compile-schemas`
fail on duplicate IDs. The backport therefore must **not** ship GTK's
`gschema.xml` files; the application uses the system schemas, which are the same
IDs and paths, so lookups resolve. This is a deliberate omission and is
commented in the packaging.

### 3. libwayland keeps its soname

`libwayland-client.so.0` is the same soname in 1.23.1 and 1.24.0, so a
private-prefix 1.24 is ABI-compatible with anything linked against the system
copy. GTK is linked against the private one via `rpath`, so no system file is
touched.

### 4. The application must find the private libraries

Celluloid links against the private GTK and libadwaita, so its binary is built
with `-Wl,-rpath,/opt/gtk420/lib` (and the private wayland lib dir). Nothing is
set in the user's environment, and no `ld.so.conf` entry is required.

## Package set

| Package | Contents | Prefix |
|---|---|---|
| `libwayland-backport` | wayland 1.24 client/server libs | `/opt/wl124` |
| `libgtk-4-1-backport` | GTK 4.20 + private wayland | `/opt/gtk420` |
| `libadwaita-1-0-backport` | libadwaita 1.8 | `/opt/gtk420` |
| `celluloid` | Celluloid 0.30, rpath-linked | `/usr` |

The three backports are private-prefix and therefore do not conflict with the
system packages. Celluloid 0.30 for trixie then depends on them rather than on
the system GTK.

## What this does NOT do

- It does not upgrade the system GTK. Other applications keep 4.18.
- It does not touch `/usr/lib`, `/usr/share/glib-2.0/schemas`, or any system
  library path.
- It is not a Debian archive-quality backport. It is a local build for users who
  specifically want 0.30 on trixie.

## Verification required before calling it done

- GTK 4.20 + libadwaita 1.8 install into the prefix without writing outside it.
- `celluloid` links to the private libraries and reports `Celluloid 0.30`.
- `ldd` shows no missing libraries.
- The binary runs on a system where the private prefix is present.
- No file ownership conflict with system packages (`dpkg -S` checks).
