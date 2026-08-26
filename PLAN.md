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
- [x] **2.4 Free `ui.Image` on reload** — done 2026-08-26 alongside 3.1, which made it urgent:
  each open now produces two images rather than one. All swaps go through `_replaceImage()`,
  which disposes the outgoing image; `State.dispose()` releases the last one. Images belonging
  to a superseded request are disposed rather than shown, guarded by `_requestId`.
  Audited again on 2026-08-26 and hardened: the preview branch had a path that adopted the image
  only when `_image == null` and silently dropped it otherwise. Unreachable today (the preview is
  awaited before the full decode is), but it would have become a ~130 MB-per-open leak the moment
  anyone applied whichever decode finished first. Every non-adopting path now disposes explicitly.
  Native side verified separately with `/tmp/leak_probe.c`: RSS flat at 12 MB across six
  decode+preview cycles of a 33MP CR3 (~98 MB allocated per pass), so `raw_free_result` and
  `raw_free_thumb` are sound.
- [ ] **2.5 Audit the isolate FFI path** — `DynamicLibrary.open` runs per decode; confirm that's
  intended (it is cheap, but worth a comment) and that `pathPtr` is freed on every exit path.
- [x] **2.6 Test with real RAW files** — done 2026-08-26 against `test-images/` (13 files:
  7× Nikon Z 6_2 NEF, 6× Canon EOS R7 CR3; gitignored, they are personal photos).
  **All 13 decode correctly** through both the C layer and the Dart FFI layer.
  Struct layouts verified: `sizeOf<RawImageResultNative>` = 32, `RawImageMetaNative` = 152,
  both matching the C side exactly. Metadata, buffer sizes and RGB→RGBA conversion all correct.
  Tool for re-running this: `dart run tool/ffi_check.dart <wrapper.so> <raw>...`
  Still unverified: `ui.decodeImageFromPixels` → canvas, which needs the GUI (see 2.8).
- [x] **2.7 Portrait images report the wrong resolution** — FIXED 2026-08-26.
  `raw_read_meta` returned `sizes.width/height` (the unrotated sensor area) while
  `dcraw_process` applies the orientation flag, so `DSC_1441.NEF` decoded to 4040×6064 while the
  EXIF panel claimed 6064×4040. The wrapper now transposes for `flip == 5 || flip == 6` and also
  exposes `flip` on the meta struct. `sizes.flip` is populated by `libraw_open_file` alone, so
  the metadata path still skips unpack/process and stays a 1–5 ms operation.
  Struct grew 152 → 156 bytes; `RawImageMetaNative` and `tool/ffi_check.dart` updated to match.
  `ffi_check` now treats a metadata/decode size disagreement as a failure rather than a note,
  and `test/preview_orientation_test.dart` asserts EXIF dimensions match the decoded image.
- [x] **2.8 Blank canvas: decoded image never rendered** — FIXED 2026-08-26.
  Symptom: opening a CR3 populated the EXIF panel and the "6984 × 4660 px / Scale: 100%" readout
  (so the `ui.Image` existed) but the canvas stayed empty.
  Cause: a childless `CustomPaint` takes its size from `size`, which defaults to `Size.zero`, and
  `Row`'s default `crossAxisAlignment.center` passes *loose* vertical constraints — so
  `constrain(Size.zero)` collapsed it to zero height. Measured: `Size(580.0, 0.0)` before,
  `Size(580.0, 552.0)` after. The image was being painted into a zero-height box all along.
  Fix: wrap the painter in `SizedBox.expand`. Regression test: `test/canvas_layout_test.dart`.
- [x] **2.9 "Fit to window" now actually fits** — FIXED 2026-08-26. The button used to just set
  `_scale = 1.0` (1:1, not fit). Now scales by the tighter of the two axes via `fitScaleFor()`,
  so the whole frame is visible. Also added a **1:1 button** for true 100%, and lowered the zoom
  floor from 0.1 to 0.01 — a 6984px image in a 1146px canvas fits at ~0.16, and a smaller window
  would have hit the old clamp. Covered by `test/fit_scale_test.dart`.

## Phase 3 — Make it usable

- [x] **3.1 Fast preview path** — done 2026-08-26. `raw_decode_thumb` in the wrapper pulls the
  embedded preview; Flutter decodes the JPEG natively, so no libjpeg dependency was needed.
  Measured on the test images:

  | file | preview | full decode | speedup |
  |---|---|---|---|
  | DSC_1436.NEF | 6048×4024, 480 ms | 6064×4040, 3431 ms | 7.1× |
  | DSC_1441.NEF (portrait) | 4024×6048, 1047 ms | 4040×6064, 3917 ms | 3.7× |
  | 20250803_A0A8111.CR3 | 6960×4640, 565 ms | 6984×4660, 3785 ms | 6.7× |

  The preview is ~99.7% of full resolution on both bodies, not a small thumbnail.
  **Orientation was the trap:** previews are stored unrotated (DSC_1441 is `flip=5` but its
  preview is a landscape 6048×4024 JPEG), while `dcraw_process` bakes rotation into the full
  decode — so a naive blit showed portrait shots sideways. `_applyFlip` handles 3/5/6, guarded
  by a runtime check for whether Flutter's codec already applied EXIF orientation.
  Pinned by `test/preview_orientation_test.dart`.
  Smaller previews (1620×1080, 640×424) are also embedded if a sub-50 ms first paint is ever
  wanted — `libraw_data_t.thumbs_list` enumerates them.
- [x] **3.1a Isolate statics do not cross isolates** — found while testing 3.1.
  `RawDecoder.libraryPathOverride` was invisible inside `Isolate.run`, which silently fell back
  to the bundle path. The `.so` path is now resolved on the main isolate and captured into the
  closure. This also affects any future static config touched by isolate code.
- [x] **3.2 Fit-to-window *on load*** — done 2026-08-26. Applied via `addPostFrameCallback` after
  the decode completes. The canvas cannot be measured at that moment: `_canvasKey` is attached to
  a widget that only exists once `_image != null`, so `_canvasSize` is still null when `setState`
  runs. Waiting one frame costs an imperceptible ~16 ms of 1:1 before it snaps to fit, and keeps
  `_scale` consistent with the sidebar readout (a `LayoutBuilder` would have fitted the image
  while the panel still displayed the stale percentage, since the panel is built before layout).
  Also added `mounted` guards around the post-await `setState` calls.
- [x] **3.7 Show the file name** — base name only, above the EXIF block, ellipsised with a
  tooltip carrying the full name.
- [ ] **3.3 Scroll-wheel zoom** centred on the cursor, and clamp panning to the image bounds.
- [ ] **3.4 Directory browsing** — arrow keys / filmstrip to move between RAWs in the same folder.
- [ ] **3.5 Command-line argument** — `raw_viewer photo.cr2` should open that file.
- [ ] **3.6 Export to JPEG/PNG** from the decoded buffer.

- [x] **2.10 EXIF panel crashed on unreadable metadata** — FIXED 2026-08-26.
  `shutterDisplay` computed `(1 / shutter).round()`, and `1 / 0` is `Infinity`, whose `.round()`
  throws `UnsupportedError` — so this took the panel down rather than merely displaying oddly
  (verified: both it and the ISO row's `.toInt()` throw). LibRaw zero-fills the meta struct on a
  failed read, which is exactly when this fires.
  All formatting now lives on `RawMeta` behind a shared `_usable()` guard rejecting zero,
  negative, NaN and Infinity, falling back to `RawMeta.unknown` ("—"): `shutterDisplay`,
  `apertureDisplay`, `isoDisplay`, `focalLenDisplay`, `cameraDisplay`, `resolutionDisplay`.
  The panel had been doing its own formatting inline, which is how ISO and focal length ended up
  with the same latent crash. Covered by `test/raw_meta_test.dart`.

## Phase 4 — Polish and durability

- [x] **4.1 `git init` + first commit** — done 2026-08-26, commit `b2c94d0`. Identity is set
  repo-locally (`sreenath.ramanna <sreenath.kr32@gmail.com>`), not globally.
- [x] **4.2 README** — done 2026-08-26. Replaced the `flutter create` boilerplate: what it is,
  per-distro dependencies (with the `LibRaw-devel` capitalisation trap called out), build and run,
  supported formats, controls, measured performance, layout, and how to run the tests and
  `tool/ffi_check.dart`.
- [x] **4.5 DESIGN.md** — done 2026-08-26. Layer-by-layer: the C API (each function, its cost,
  ownership rules, struct layouts with byte sizes), the FFI mirror, the Dart wrapper (isolate
  threading, the statics-don't-cross-isolates trap, orientation normalisation, `RawMeta`
  formatting guards), and the UI (widget tree, the load-bearing `SizedBox.expand`, zoom, the
  loading sequence, image lifetime). Ends with a *Known gaps* section covering the missing error
  detail, dead 16-bit path, untested `colors == 4` branch, undetectable 180° preview rotation,
  and absent caching.
- [ ] **4.3 Tests** — unit-test `RawMeta.shutterDisplay` / `apertureDisplay` edge cases
  (`shutter == 0` currently divides by zero), plus an FFI smoke test.
- [ ] **4.4 Basic adjustments** — exposure / white balance sliders re-running `dcraw_process`.

---

## Notes / decisions

- LibRaw is linked via `pkg-config libraw`; the wrapper is plain C, built as a shared lib and
  loaded at runtime from `$ORIGIN/lib/libraw_wrapper.so`.
- Decode runs in `Isolate.run` so the UI thread stays free; the `ui.Image` must be built back on
  the main isolate (`ui.decodeImageFromPixels`), which is why the isolate returns raw RGBA bytes.
