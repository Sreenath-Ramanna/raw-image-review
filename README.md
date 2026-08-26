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

```bash
./scripts/setup.sh          # dependencies, once
flutter run -d linux        # or: flutter build linux
```

The built bundle lands in `build/linux/x64/{debug,release}/bundle/`, with
`libraw_wrapper.so` in its `lib/` subdirectory next to the executable.

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

Untick **Confirm delete** to cull without a prompt on each file.

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
| Nikon Z 6_2 NEF (24 MP) | ~480 ms | ~3.4 s |
| Canon EOS R7 CR3 (33 MP) | ~570 ms | ~3.8 s |

Metadata alone takes 1–5 ms, so the EXIF panel fills in immediately. The
embedded preview is roughly 99.7% of full resolution on both bodies, so the
first paint is near-full quality rather than a placeholder.

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
