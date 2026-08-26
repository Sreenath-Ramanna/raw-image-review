# raw_viewer — Completion Plan

Camera RAW image viewer for Linux. Flutter UI + C (LibRaw) decode core, joined by `dart:ffi`.

**Status legend:** `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

Last updated: 2026-08-26

---

## Phase 1 — Make it build (goal: `flutter build linux` succeeds) ✅ COMPLETE

- [!] **1.1 Install system dependencies** — `libraw-devel`, `gtk3-devel`, `cmake`, `ninja-build`, `clang`, `pkg-config`.
  **BLOCKED: needs sudo, and sudo cannot prompt for a password without a TTY — run it in a
  normal terminal, not through Claude Code:**
  ```
  sudo dnf install -y LibRaw-devel cmake ninja-build gtk3-devel clang pkgconf-pkg-config
  ```
  Fedora package-name gotchas (all confirmed against F44 repos on 2026-08-26):
  `LibRaw-devel` is capitalised — `libraw-devel` does not exist, and `libraw1394-devel` is a
  FireWire library, not this. `pkg-config` is only a virtual provide; the package is
  `pkgconf-pkg-config`, and it is already installed here. Fedora ships LibRaw 0.22.2.
  Verify with `pkg-config --modversion libraw`. As of 2026-08-26 none of the others are installed.
- [x] **1.2 Generate the Flutter Linux scaffold** — done via `flutter create --platforms=linux .`.
  Created `linux/runner/{main.cc,my_application.cc,my_application.h}`, `linux/flutter/`,
  `.metadata`, `analysis_options.yaml`, `test/`, `README.md`.
  Note: `flutter create` does *not* overwrite existing files — `lib/`, `pubspec.yaml` came through
  untouched. Backup of the originals is at `/tmp/raw_viewer_backup/` (delete once satisfied).
- [x] **1.3 Re-apply the LibRaw build rules** — `linux/CMakeLists.txt` rewritten from the canonical
  Flutter template + the `raw_wrapper` target. Key points: `project(... LANGUAGES CXX C)` because the
  wrapper is C; `apply_standard_settings()` is deliberately not applied to it (it forces a C++ std);
  installs to `bundle/lib/` so `$ORIGIN/lib` and `RawDecoder._soPath` line up.
- [x] **1.4 Remove the duplicate `src/CMakeLists.txt`** — deleted.
- [x] **1.5 `flutter pub get`** — resolved. Added `flutter_lints` (the generated
  `analysis_options.yaml` includes it but it was not in `dev_dependencies`).
- [x] **1.6 `flutter build linux`** — **succeeds** (2026-08-26). Verified in
  `build/linux/x64/debug/bundle/`: the `raw_viewer` binary is present, `lib/libraw_wrapper.so`
  is installed alongside it, exports all three symbols (`raw_decode_file`, `raw_read_meta`,
  `raw_free_result`), and links `libraw.so.25`. `_soPath` resolves to exactly this location.
  The C wrapper also compiles clean under `-Wall -Wextra` against LibRaw 0.22.2 — no API drift.
- [x] **1.7 `flutter analyze`** — clean, 0 issues.
- [x] **1.8 Fix a compile error the code had never hit** — `Colors.white87` does not exist in Flutter
  (`viewer_screen.dart:262`); replaced with `Color(0xDEFFFFFF)`. Proof the Dart had never been built.
- [x] **1.9 Replace the stub widget test** — `flutter create` wrote a counter test referencing a
  `MyApp` that does not exist; swapped for a real empty-state smoke test. `flutter test` passes.

## Phase 2 — Make it correct (goal: it actually opens a RAW file without leaking or lying)

- [ ] **2.1 Check `raw_read_meta`'s return value** — `raw_decoder.dart` ignores it today; a failed
  metadata read silently yields a zeroed struct and the EXIF panel shows "0 ISO, f/0.0".
- [ ] **2.2 Fix the `colors == 4` path** — `rgba.setAll(0, srcBytes)` assumes `dataSize == w*h*4`;
  guard it, and handle `bits == 16` (currently `output_bps` is hardcoded to 8, so 16-bit is dead code —
  either wire it up or reject it explicitly).
- [ ] **2.3 Surface LibRaw's error string** — the wrapper returns `NULL` for every failure, so the UI
  can only say "failed to decode". Return the LibRaw error code and map it via `libraw_strerror`.
- [ ] **2.4 Free `ui.Image` on reload** — `_decodeFile` drops the old `ui.Image` without `dispose()`,
  leaking GPU memory on every open.
- [ ] **2.5 Audit the isolate FFI path** — `DynamicLibrary.open` runs per decode; confirm that's
  intended (it is cheap, but worth a comment) and that `pathPtr` is freed on every exit path.
- [x] **2.6 Test with real RAW files** — done 2026-08-26 against `test-images/` (13 files:
  7× Nikon Z 6_2 NEF, 6× Canon EOS R7 CR3; gitignored, they are personal photos).
  **All 13 decode correctly** through both the C layer and the Dart FFI layer.
  Struct layouts verified: `sizeOf<RawImageResultNative>` = 32, `RawImageMetaNative` = 152,
  both matching the C side exactly. Metadata, buffer sizes and RGB→RGBA conversion all correct.
  Tool for re-running this: `dart run tool/ffi_check.dart <wrapper.so> <raw>...`
  Still unverified: `ui.decodeImageFromPixels` → canvas, which needs the GUI (see 2.8).
- [ ] **2.7 Portrait images report the wrong resolution** — found by 2.6. `raw_read_meta` returns
  `sizes.width/height`, which is the *unrotated* sensor area, but `dcraw_process` applies the
  camera orientation flag. So `DSC_1441.NEF` decodes to 4040×6064 while the EXIF panel
  (`viewer_screen.dart:233`) reports 6064×4040. The displayed pixels are correct — only the
  metadata line lies, and only for portrait shots.
  Fix: use `sizes.iwidth/iheight` (post-flip dims) in the wrapper, or consult `sizes.flip`
  and swap. Verify `iwidth/iheight` are populated after `libraw_open_file` alone, since
  `raw_read_meta` deliberately skips unpack/process.
- [x] **2.8 Blank canvas: decoded image never rendered** — FIXED 2026-08-26.
  Symptom: opening a CR3 populated the EXIF panel and the "6984 × 4660 px / Scale: 100%" readout
  (so the `ui.Image` existed) but the canvas stayed empty.
  Cause: a childless `CustomPaint` takes its size from `size`, which defaults to `Size.zero`, and
  `Row`'s default `crossAxisAlignment.center` passes *loose* vertical constraints — so
  `constrain(Size.zero)` collapsed it to zero height. Measured: `Size(580.0, 0.0)` before,
  `Size(580.0, 552.0)` after. The image was being painted into a zero-height box all along.
  Fix: wrap the painter in `SizedBox.expand`. Regression test: `test/canvas_layout_test.dart`.
- [ ] **2.9 "Fit to window" does not fit** — the button (`viewer_screen.dart:145`) just sets
  `_scale = 1.0`, which is 1:1, not fit. Same root cause as 3.2; fix them together.

## Phase 3 — Make it usable

- [ ] **3.1 Fast preview path** — decode the embedded JPEG thumbnail (`libraw_dcraw_thumb`) first for
  instant display, then swap in the full decode. **Measured 2.1–3.5 s per file** on this machine
  (Z 6_2 24MP ≈ 2.2 s, R7 33MP ≈ 2.8 s), so this is the single biggest usability win available.
  Metadata alone is 1–5 ms, so the EXIF panel can populate essentially instantly.
- [ ] **3.2 Fit-to-window on load** — `_scale = 1.0` means a 8000px image opens at 1:1 and overflows.
  Compute the fit scale from the canvas size instead.
- [ ] **3.3 Scroll-wheel zoom** centred on the cursor, and clamp panning to the image bounds.
- [ ] **3.4 Directory browsing** — arrow keys / filmstrip to move between RAWs in the same folder.
- [ ] **3.5 Command-line argument** — `raw_viewer photo.cr2` should open that file.
- [ ] **3.6 Export to JPEG/PNG** from the decoded buffer.

## Phase 4 — Polish and durability

- [x] **4.1 `git init` + first commit** — done 2026-08-26, commit `b2c94d0`. Identity is set
  repo-locally (`sreenath.ramanna <sreenath.kr32@gmail.com>`), not globally.
- [ ] **4.2 README** — what it is, dependencies, build steps, supported formats.
- [ ] **4.3 Tests** — unit-test `RawMeta.shutterDisplay` / `apertureDisplay` edge cases
  (`shutter == 0` currently divides by zero), plus an FFI smoke test.
- [ ] **4.4 Basic adjustments** — exposure / white balance sliders re-running `dcraw_process`.

---

## Notes / decisions

- LibRaw is linked via `pkg-config libraw`; the wrapper is plain C, built as a shared lib and
  loaded at runtime from `$ORIGIN/lib/libraw_wrapper.so`.
- Decode runs in `Isolate.run` so the UI thread stays free; the `ui.Image` must be built back on
  the main isolate (`ui.decodeImageFromPixels`), which is why the isolate returns raw RGBA bytes.
