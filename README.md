# raw_viewer

A camera RAW image viewer for Linux desktop. Flutter for the UI, C for the
decoding, joined by `dart:ffi`.

Open a `.NEF`, `.CR3` or other RAW file and it appears fitted to the window with
its EXIF data alongside. The camera's embedded JPEG preview is shown first — in
roughly half a second — while the full demosaic runs in the background and
replaces it a few seconds later.

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
| **Fit to window** | Scales so the whole frame is visible |
| **1:1** | Actual size, one image pixel per screen pixel |
| **Zoom in / out** | 1.25× steps |
| Drag on the image | Pan |

The folder scan is not recursive, matches extensions case-insensitively, and
sorts by name. The toolbar shows the position in the folder, e.g. `3 / 13`.

Files open fitted to the window. The EXIF panel shows the file name, camera,
resolution, ISO, shutter, aperture and focal length; anything the file does not
provide reads `—`.

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
lib/src/viewer_screen.dart    toolbar, image canvas, EXIF panel
lib/main.dart                 app entry point
linux/CMakeLists.txt          Flutter runner plus the raw_wrapper target
tool/ffi_check.dart           drives the .so through the real bindings, no UI
scripts/setup.sh              dependency installation
```

`DESIGN.md` describes the C API, the Dart wrapper and the UI in detail.
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
