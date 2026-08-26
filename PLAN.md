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
- [x] **3.4 Directory browsing** — done 2026-08-26. "Open RAW" became "Open Folder": it scans the
  chosen folder for RAW files, sorts by name, and opens the first. Previous/Next buttons plus
  ← / → keys move through the list, with a "3 / 13" position readout.
  Notes: extension matching is case-insensitive, since cameras write `.NEF` and `.CR3` upper case
  and a naive match would find nothing. The scan is deliberately non-recursive — a shoot folder is
  the unit people browse. Keyboard handling takes `KeyDownEvent` only; honouring auto-repeat would
  queue a multi-second decode per repeat while a key is held. Focus is explicitly reclaimed after
  the picker closes, otherwise the arrow keys are dead until the user clicks the window.
  Covered by `test/raw_files_in_test.dart`.
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

## Phase 5 — Open at 100% centred on the focus point ✅ COMPLETE

Goal: instead of fitting the whole frame, open each image at 1:1 centred on where the camera
focused — the view a photographer actually wants first, to check critical sharpness.

### Investigation (do this before writing any code)

- [x] **5.1 Research how AF point data is stored** — done 2026-08-26. Both vendors use MakerNotes,
  with nothing in common: Canon `0x0026` (AFInfo2, origin at image **centre**, signed), Nikon
  `0x00b7` (AFInfo2, origin **top-left**, unsigned). See `FOCUS_POINTS.md`.
- [x] **5.2 Verify the data is present in the test images** — **yes, in both.** `afcount == 1` for
  every file. Canon: 5472-byte blob, `NumAFPoints=651`, `ValidAFPoints=1`, in-focus point at
  `(-783,-423)` with a 163×163 area. Nikon: 56-byte blob, one area at `(4068,2864)` sized 285×308.
  X/Y vary per image while the area size stays fixed, confirming the offsets are right.
- [x] **5.3 Write `FOCUS_POINTS.md`** — done, including layouts, verified samples, coordinate
  mapping, and open questions.
- [x] **5.3a Canon Y direction — RESOLVED 2026-08-26: positive Y is UP.** Confirmed by the user
  against real EOS R7 frames, the marker landing on the intended subjects. The two references
  contradicted each other; the one claiming "+Y up for EOS" was right, and the chiark-rendered
  ExifTool table claiming downward was wrong. `FocusPoint.canonPositiveYIsUp` stays a switch
  rather than a constant, since PowerShot bodies use the opposite convention and other EOS
  generations are untested.

### Extraction path (decide once 5.1–5.3 are known)

- [x] **5.4 Choose how to read it** — decided 2026-08-26: **a hybrid of (a) and (b)**. LibRaw does
  not decode AF points into named fields, but `imgdata.makernotes.common.afdata[]` hands over the
  raw MakerNote blob with its tag id, populated by `libraw_open_file` alone — so it stays inside the
  1–5 ms metadata budget. We parse the blob ourselves in the wrapper. No MakerNote IFD walking and
  no `exiftool` runtime dependency. The vendor structs (`makernotes.canon`, `makernotes.nikon`)
  are useless here — Canon's carries only `AFMicroAdj*`.
- [x] **5.5 Extend the C API** — done 2026-08-26. New `raw_read_focus()` and `RawFocusPoint`
  struct, kept separate from `RawImageMeta` so that layout stays stable. Returns the vendor's
  **raw** values, not a resolved pixel position — see 5.7.
- [x] **5.6 Thread through the FFI and decoder layers** — done. `RawFocusPointNative`, read inside
  both isolate paths (preview and full decode), carried on `DecodedRawImage.focus`.

### Coordinate handling (the part most likely to be wrong)

- [x] **5.7 Map AF coordinates onto the decoded image** — done, in `lib/src/focus_point.dart`.
  Interpretation lives in **Dart, not C**, so the Canon Y switch needs no native rebuild and the
  three stacked transforms (vendor origin/sign → AF-space scaling → rotation) are unit-testable.
  `focus_point.dart` is deliberately free of `dart:ui` so `tool/ffi_check.dart` can use it too.
- [x] **5.8 Verify against a known image** — **confirmed 2026-08-26.** The user checked the
  rendered markers against the subjects they had actually shot and reported the Canon
  interpretation correct. Together with the end-to-end arithmetic check in `tool/ffi_check.dart`
  (every test file resolves, including the rotated portrait frames), the feature is verified.

### UI

- [x] **5.9 Open at 1:1 centred on the focus point** — done, replacing fit-on-load. `_centreOn()`
  offsets by the distance from the image centre to the target, scaled.
- [x] **5.10 Fall back to fit-to-window** — done, silently, in `_showInitialView()`. The
  focus-related toolbar buttons disable themselves when a file records no AF data.
- [x] **5.11 Focus point overlay** — done, on by default, with a toolbar toggle and a
  "centre on focus point" button. Drawn deliberately prominently (green box, black outline for
  contrast, centre cross) because its main job is making a wrong interpretation obvious.
- [x] **5.12 Tests** — `test/focus_point_test.dart`, 14 cases: vendor origins, the Canon Y switch
  mirroring across the centre line, per-axis scaling, all four rotations staying inside the image
  bounds, and null returns for unusable data.

---

## Phase 6 — Culling ✅ COMPLETE

- [x] **6.1 Delete the current image** — done 2026-08-27. Toolbar Delete button, placed at the far
  end away from Previous/Next so a stray click while browsing cannot trash a frame.
- [x] **6.2 Remove it from the browsing list** — `indexAfterRemoval()` decides what to show next:
  hold the index (landing on what was the next frame, so culling flows forward), step back when
  the last entry goes, null when the folder empties. Previous/Next can no longer reach the
  deleted file. Bumps `_requestId` on emptying so an in-flight decode does not paint over the
  empty state.
- [x] **6.3 "Confirm delete" checkbox** — on by default; controls whether the dialog appears.
  Focus is reclaimed after the dialog closes, same trap as the folder picker (3.4).
- [x] **6.4 Trash rather than unlink** — user's call, taken 2026-08-27. `gio trash` keeps a
  mis-culled keeper recoverable. `gio` ships with glib2 which GTK already requires.
  **Found while testing:** `gio trash` refuses tmpfs with "Trashing on system internal mounts is
  not supported", which is why the test creates its temp dir under `$HOME` rather than `/tmp`,
  and why the wrapper surfaces gio's own stderr instead of a generic message.
- [x] **6.5 Tests** — `test/delete_test.dart`: every removal case including an exhaustive
  bounds sweep, plus a real `gio trash` round trip that cleans up after itself.

---

## Phase 7 — Build configuration

- [x] **7.1 Produce a release build** — done 2026-08-27. Everything up to this point had been
  `--debug`; `build/linux/x64/` contained only `debug/`. Release compiles clean, no `-Werror`
  or optimisation issues in the wrapper.
- [x] **7.2 Measure debug vs release properly** — done, with `tool/bench.dart` timing the C decode
  and the Dart conversion loop separately, run both JIT and AOT.
  **Result: end-to-end decode is unchanged** (2724 ms debug vs 2719 ms release, mean over three
  files). The Dart RGB→RGBA loop *is* ~1.55× faster AOT (225 → 145 ms), but it is only ~8% of the
  work. The C decode does not improve at all — `libraw_wrapper.c` is a thin shim and the real work
  is inside the distribution's prebuilt `libraw.so`, identical in both builds, so `-O3` on ~230
  lines of glue buys nothing. Confirmed by timing both `.so` files from a pure-C harness.
  Release is still worth using: **48 MB vs 147 MB** and a faster start.
  This corrected an earlier assumption that release would meaningfully speed up decoding.
- [x] **7.3 Document it** — README gained a debug-vs-release table with reproduction steps and now
  recommends `--release` for real use; DESIGN.md records why `-O3` on the wrapper is irrelevant.
- [ ] **7.4 Measure the preview path in release** — the ~480/570 ms preview figures are still JIT
  measurements from `test/preview_orientation_test.dart`. Most of that time is JPEG decoding inside
  Skia rather than Dart, so it is unlikely to move, but it has not been measured.

---

## Notes / decisions

- LibRaw is linked via `pkg-config libraw`; the wrapper is plain C, built as a shared lib and
  loaded at runtime from `$ORIGIN/lib/libraw_wrapper.so`.
- Decode runs in `Isolate.run` so the UI thread stays free; the `ui.Image` must be built back on
  the main isolate (`ui.decodeImageFromPixels`), which is why the isolate returns raw RGBA bytes.
