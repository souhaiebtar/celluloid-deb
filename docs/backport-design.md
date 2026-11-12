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

trixie's protocol XML only defines `released` and `pressed`:

```
$ grep -A6 '<enum name="key_state"' /usr/share/wayland/wayland.xml
      <entry name="released" value="0" .../>
      <entry name="pressed"  value="1" .../>
```

So GTK 4.20 cannot compile its Wayland backend without a newer Wayland.

### Wayland is a build-time dependency only

This is the useful part, and it was measured rather than assumed. After building
GTK 4.20 against wayland 1.24, every `wl_*` symbol the library imports was
checked against trixie's own `libwayland-client.so.0` (1.23.1):

```
ALL_WAYLAND_SYMBOLS_PRESENT_IN_SYSTEM
```

and `ldd` on the final Celluloid binary resolves Wayland from the system:

```
libgtk-4.so.1          => /opt/gtk420/lib/x86_64-linux-gnu/libgtk-4.so.1
libadwaita-1.so.0      => /opt/gtk420/lib/x86_64-linux-gnu/libadwaita-1.so.0
libwayland-client.so.0 => /lib/x86_64-linux-gnu/libwayland-client.so.0
0 missing
```

Consequence: **no runtime Wayland package is needed**. Wayland 1.24 is built
inside the GTK build container and is never installed on the user's system. The
`new enum` is a protocol-generation concern, not a runtime ABI one. That removes
a whole package from the shipped set and removes any risk of shadowing the
system Wayland.

The alternative — GTK with `-Dwayland-backend=false` — compiles but loses native
Wayland, leaving Celluloid on XWayland. That was rejected.

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
| `libgtk-4-1-backport` | GTK 4.20 | `/opt/gtk420` |
| `libadwaita-1-0-backport` | libadwaita 1.8 | `/opt/gtk420` |
| `celluloid` | Celluloid 0.30, rpath-linked | `/usr` |

Wayland 1.24 is **not** shipped: it is built inside the GTK build container only,
because the runtime needs none of its new symbols (verified above).

The two backports are private-prefix and therefore do not conflict with the
system packages. Celluloid 0.30 for trixie then depends on them rather than on
the system GTK.

## How to build it

```bash
./build-backports.sh     # GTK 4.20 + libadwaita 1.8  (~10 min the first time)
./build.sh trixie        # Celluloid 0.30 against them
```

`build.sh` detects `dist/backports/` and, when present, resolves trixie to
`gtk4 4.20.4 / adw 1.8.8`, which makes 0.30 resolvable. Without them the same
command resolves 0.29 and builds that instead. `--no-backports` forces the old
behaviour.

Install order matters for the packages, not for apt:

```bash
sudo apt install ./dist/backports/*.deb ./dist/trixie/celluloid_0.30-1~trixie_amd64.deb
```

apt resolves the order itself, because celluloid's `Depends` names
`libgtk-4-1-backport (>= 4.20)` and `libadwaita-1-0-backport (>= 1.8)`.

## What this does NOT do

- It does not upgrade the system GTK. Other applications keep 4.18.
- It does not install or shadow the system Wayland.
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

## Verification results

All of the above were checked inside a clean `debian:13` container.

Installing the two packages:

```
Setting up libgtk-4-1-backport (4.20.4-1~trixie) ...
Setting up libadwaita-1-0-backport (1.8.8-1~trixie) ...
installed ok
```

Nothing outside the private prefix:

```
$ dpkg -L libgtk-4-1-backport | grep -v '^/opt' | grep -v '^/usr/share/doc'
/.
/usr
/usr/share
```

Celluloid 0.30 built against them:

```
gtk4:       4.20.4
libadwaita: 1.8.8
CELLULOID_030_BUILD_OK
RUNPATH:    /opt/gtk420/lib/x86_64-linux-gnu
private libs: 2
missing:      0
$ celluloid --version
Celluloid 0.30
```

### Building against the backports needs trixie's own dev packages

GTK's `gtk4.pc` legitimately declares an external `Requires` chain, so a
dependent build needs the corresponding trixie `-dev` packages present:

```
pango, pangocairo, gdk-pixbuf-2.0, cairo, cairo-gobject,
graphene-gobject-1.0, gio-2.0
```

plus `libappstream-dev` for libadwaita and `libepoxy-dev` for Celluloid itself.
These are build-time only; the runtime dependencies are the normal trixie
libraries, which is why the built binary resolves cleanly against the system.

### Package contents

| Package | Size | Notes |
|---|---|---|
| libgtk-4-1-backport | 8.5 MB | headers and `.pc` included, so it is self-sufficient as a dev dependency |
| libadwaita-1-0-backport | 0.8 MB | depends on `libgtk-4-1-backport (>= 4.20)` |

Wayland libraries are not bundled: the built `libgtk-4.so.1` resolves
`libwayland-client.so.0` from the system, as measured earlier.
