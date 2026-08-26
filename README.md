# raw_viewer

A camera RAW image viewer for Linux desktop. Flutter for the UI, C for the
decoding, joined by `dart:ffi`.

Open a folder of RAW files and browse it with the arrow keys. Each image opens
at 1:1 centred on the camera's focus point, with its EXIF data alongside. The
camera's embedded JPEG preview appears first — in roughly half a second — while
the full demosaic runs in the background and replaces it a few seconds later.

## Requirements

- Linux with GTK 3
- Flutter SDK 3.0 or newer
- LibRaw development headers

Fedora:

```bash
sudo dnf install -y LibRaw-devel cmake ninja-build gtk3-devel clang pkgconf-pkg-config
```

Debian / Ubuntu:

```bash
sudo apt-get install -y libraw-dev cmake ninja-build libgtk-3-dev clang pkg-config
```

`scripts/setup.sh` picks the right set for your distribution and then runs
`flutter pub get`.

> The Fedora package is `LibRaw-devel`, capitalised. A lowercase `libraw-devel`
> does not exist, and `libraw1394-devel` is an unrelated FireWire library that
> will install cleanly and not help.

## Build and run

Install the dependencies once:

```bash
./scripts/setup.sh
```

### Release — use this one

```bash
flutter build linux --release
./build/linux/x64/release/bundle/raw_viewer
```

A third of the size of a debug build and faster to start. Decode speed is
effectively identical — see [Debug vs release](#debug-vs-release).

### Debug — for development

```bash
flutter build linux --debug
./build/linux/x64/debug/bundle/raw_viewer
```

Or let Flutter build and launch in one step, with hot reload attached:

```bash
flutter run -d linux
```

`flutter run` is the better development loop: press `r` to hot-reload Dart
changes without restarting, `q` to quit. Note that changes to
`src/libraw_wrapper.c` are **not** picked up by hot reload — restart
`flutter run`, or re-run `flutter build`, to recompile the native library.

### Running the built binary

Either bundle can be launched from any working directory, using an absolute or
relative path:

```bash
/home/you/raw_viewer/build/linux/x64/release/bundle/raw_viewer
```

The executable finds its resources relative to itself, so **the bundle must stay
intact**. Copying just the executable elsewhere fails with:

```
error while loading shared libraries: libflutter_linux_gtk.so: cannot open shared object file
```

To install it somewhere permanent, move the whole `bundle/` directory and run
the `raw_viewer` inside it — or symlink to that executable, which is fine
because the symlink is resolved before the resource lookup:

```bash
cp -r build/linux/x64/release/bundle ~/.local/opt/raw_viewer
ln -sf ~/.local/opt/raw_viewer/raw_viewer ~/.local/bin/raw_viewer
raw_viewer            # if ~/.local/bin is on your PATH
```

The bundle contains the executable, `data/` (Flutter assets and ICU data), and
`lib/` (the Flutter engine plus `libraw_wrapper.so`). `libraw_wrapper.so` is
loaded lazily on the first image you open, not at startup.

### Desktop entry and icon

```bash
./scripts/install-desktop.sh              # install
./scripts/install-desktop.sh --uninstall  # remove
```

This adds a menu entry and installs the app icon into the hicolor theme, all
under `~/.local/share` — no root required.

**On Wayland this is what makes the window icon appear at all.** A Wayland
compositor ignores `gtk_window_set_icon_list()` and instead matches the window's
app id (`com.example.raw_viewer`) against a `.desktop` file of the same name,
taking the icon from there. Without the install you get a generic placeholder no
matter what the application code does. On X11 the in-process icon works by
itself, and this just adds the menu entry.

The `.desktop` file records an absolute path to the executable, so re-run the
script if you move the bundle.

The icon is generated, not hand-drawn — `python3 tool/make_icon.py` redraws all
eight sizes from geometry in `tool/make_icon.py`.

## Supported formats

Canon `.cr2` `.cr3`, Nikon `.nef`, Sony `.arw`, Fujifilm `.raf`, Adobe `.dng`,
Olympus `.orf`, Pentax `.pef`, Panasonic `.rw2`, and generic `.raw`. Anything
LibRaw can read will decode; this list is what the file picker offers.

Verified against Nikon Z 6_2 (NEF) and Canon EOS R7 (CR3) files with LibRaw
0.22.2.

## Using it

| Control | Effect |
|---|---|
| **Open Folder** | Loads every RAW in the folder and shows the first |
| **← / →**, or Previous / Next | Move through the folder |
| **Del** | Same as the Delete button — obeys "Confirm delete" |
| **Focus point** | Toggles the marker showing where the camera focused |
| **Centre on focus** | Jumps back to 1:1 on the focus point |
| **Fit to window** | Scales so the whole frame is visible |
| **1:1** | Actual size, one image pixel per screen pixel |
| **Zoom in / out** | 1.25× steps |
| Drag on the image | Pan |
| **Delete** | Moves the current file to the Trash and drops it from the list |
| **Confirm delete** | When ticked (default), asks before each delete |

The folder scan is not recursive, matches extensions case-insensitively, and
sorts by name. The toolbar shows the position in the folder, e.g. `3 / 13`.

### Culling

Delete moves the file to the desktop Trash via `gio trash` rather than
unlinking it, so a mis-click on a keeper is recoverable from your file manager.
Disk space is reclaimed when you empty the Trash. The deleted file is removed
from the browsing list immediately, so Previous/Next never return to it, and the
viewer advances to the next frame — or steps back if you deleted the last one.

Untick **Confirm delete** to cull without a prompt on each file — with it off,
`Del` discards the current frame in a single keystroke, which is the fast path
through a shoot.

Note: `gio trash` refuses to trash files on tmpfs and similar system-internal
mounts. Photos on a normal disk or removable card are fine; the error is
reported in the viewer if it happens.

Files open at **1:1, centred on the camera's focus point**, so critical
sharpness is the first thing on screen. Files with no recorded AF data fall back
to fit-to-window. See `FOCUS_POINTS.md` for how that data is stored — and note
the Canon Y-direction switch documented there, which may need flipping.

The EXIF panel shows the file name, camera, resolution, ISO, shutter, aperture
and focal length; anything the file does not provide reads `—`.

## Performance

Full decode is the slow part, and it dominates regardless of file size:

| File | Preview | Full decode |
|---|---|---|
| Nikon Z 6_2 NEF (24 MP) | ~480 ms | ~2.5 s |
| Canon EOS R7 CR3 (33 MP) | ~570 ms | ~2.8 s |

Metadata alone takes 1–5 ms, so the EXIF panel fills in immediately. The
embedded preview is roughly 99.7% of full resolution on both bodies, so the
first paint is near-full quality rather than a placeholder.

### Debug vs release

Measured with `tool/bench.dart`, mean over three files, best of three passes:

| | debug | release |
|---|---|---|
| LibRaw decode (C) | 2498 ms | 2574 ms |
| RGB→RGBA (Dart) | 225 ms | 145 ms |
| **total** | **2724 ms** | **2719 ms** |
| bundle size | 147 MB | 48 MB |

The Dart conversion loop is genuinely ~1.55× faster AOT-compiled, but it is only
about 8% of the work, so end-to-end decode is unchanged. The C decode does not
improve either: `libraw_wrapper.c` is a thin shim and all the real work happens
inside the distribution's prebuilt `libraw.so`, which is the same binary in both
builds — so `-O3` on ~230 lines of glue buys nothing. The difference between
the two runs above is run-to-run noise, confirmed by timing both `.so` files
from a pure-C harness.

Release is still the right choice for use — a third of the size and a faster
start — just not for decode throughput.

To reproduce:

```bash
dart run tool/bench.dart build/linux/x64/debug/bundle/lib/libraw_wrapper.so test-images/*.NEF
dart compile exe tool/bench.dart -o /tmp/bench
/tmp/bench build/linux/x64/release/bundle/lib/libraw_wrapper.so test-images/*.NEF
```

## Layout

```
src/libraw_wrapper.c        C wrapper over LibRaw -> libraw_wrapper.so
lib/src/libraw_bindings.dart  dart:ffi structs and symbol lookups
lib/src/raw_decoder.dart      isolate decoding, pixel conversion, orientation
lib/src/focus_point.dart      AF coordinate mapping (no dart:ui, so tool/ can use it)
lib/src/viewer_screen.dart    toolbar, image canvas, EXIF panel
lib/main.dart                 app entry point
linux/CMakeLists.txt          Flutter runner plus the raw_wrapper target
tool/ffi_check.dart           drives the .so through the real bindings, no UI
tool/bench.dart               times the C decode and the Dart conversion separately
tool/make_icon.py             regenerates the app icon at every size
linux/packaging/              .desktop entry template
scripts/setup.sh              dependency installation
```

`DESIGN.md` describes the C API, the Dart wrapper and the UI in detail.
`FOCUS_POINTS.md` documents how Canon and Nikon store focus point data.
`PLAN.md` tracks completed and outstanding work.

## Development

```bash
flutter analyze
flutter test
```

`test/preview_orientation_test.dart` needs a built `libraw_wrapper.so` and RAW
files in `test-images/`; it skips itself when either is missing. The other tests
have no such requirement.

To exercise the native layer without the UI — useful after touching the C
wrapper — run:

```bash
dart run tool/ffi_check.dart \
  build/linux/x64/debug/bundle/lib/libraw_wrapper.so test-images/*.NEF
```

It verifies the Dart and C struct layouts agree, then decodes each file and
checks the buffer sizes and metadata are self-consistent.

`test-images/` and `debug_images/` are gitignored local scratch directories.
