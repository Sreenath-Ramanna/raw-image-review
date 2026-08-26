# raw_viewer — Design

How the three layers fit together, and why they are arranged this way.

```
┌─────────────────────────────────────────────────────────────┐
│  viewer_screen.dart      toolbar · canvas · EXIF panel      │  Flutter widgets
├─────────────────────────────────────────────────────────────┤
│  raw_decoder.dart        isolates · pixels · orientation    │  Dart, framework-aware
├─────────────────────────────────────────────────────────────┤
│  libraw_bindings.dart    structs · symbol lookups           │  dart:ffi, no framework
├─────────────────────────────────────────────────────────────┤
│  libraw_wrapper.so       raw_decode_file · raw_read_meta …  │  C
├─────────────────────────────────────────────────────────────┤
│  LibRaw 0.22.2                                              │  system library
└─────────────────────────────────────────────────────────────┘
```

The split exists because decoding a RAW is seconds of CPU work that must not
touch the UI thread, and because LibRaw is a C library with no Dart equivalent.
Everything below `raw_decoder.dart` is deliberately framework-free so it can run
inside a worker isolate.

---

## 1. The C layer — `src/libraw_wrapper.c`

A thin translation layer over LibRaw's C API, built as a standalone shared
library (`libraw_wrapper.so`) and loaded at runtime with `dlopen`. It is **not**
linked into the Flutter runner.

It exists to flatten LibRaw's large `libraw_data_t` into a handful of structs
with a stable, FFI-friendly layout. Describing `libraw_data_t` to Dart directly
would mean mirroring hundreds of fields and re-checking them on every LibRaw
release.

### Design rules

- **Every function returns a pointer or an int; never a struct by value.**
  Struct-return ABI is the fiddliest thing to get right across FFI.
- **Every allocation has a matching free function.** The caller owns what it
  receives and must return it.
- **`NULL` means failure.** No error strings today; see *Known gaps*.
- **The structs are append-only.** Fields are added at the end, because
  inserting one silently corrupts every field after it on the Dart side.

### Data structures

```c
typedef struct {
    unsigned char* data;      /* pixel bytes, tightly packed        */
    int width, height;
    int colors;               /* 3 = RGB, 4 = RGBA                  */
    int bits;                 /* bits per channel; always 8 today   */
    int data_size;            /* width * height * colors * bits/8   */
} RawImageResult;             /* 32 bytes */

typedef struct {
    unsigned char* data;      /* JPEG stream, or raw RGB            */
    int data_size;
    int format;               /* 1 = JPEG, 2 = uncompressed RGB     */
    int width, height;
    int flip;                 /* orientation, NOT yet applied       */
} RawThumbResult;             /* 32 bytes */

typedef struct {
    char  make[64];
    char  model[64];
    float iso_speed;
    float shutter;            /* seconds                            */
    float aperture;
    float focal_len;
    int   width, height;      /* as displayed, orientation applied  */
    int   flip;
} RawImageMeta;               /* 156 bytes */
```

Sizes are listed because `tool/ffi_check.dart` asserts them against
`sizeOf<...>()` on the Dart side at startup. That check is the cheapest possible
guard against layout drift, which otherwise shows up as plausible-looking
garbage rather than a crash.

### API

#### `RawImageResult* raw_decode_file(const char* path)`

Full decode: `libraw_open_file` → `libraw_unpack` → `libraw_dcraw_process` →
`libraw_dcraw_make_mem_image`. Returns 8-bit RGB at full resolution with the
camera white balance applied, or `NULL` on any failure.

**Costs 2–4 seconds** for a 24–33 MP frame. This is inherent to demosaicing, not
overhead that can be tuned away.

Processing parameters are fixed: `use_camera_wb = 1`, `output_bps = 8`,
`half_size = 0`, `no_auto_bright = 0`.

Free with `raw_free_result`.

#### `int raw_read_meta(const char* path, RawImageMeta* out)`

Fills a caller-allocated struct. Returns 0 on success, -1 on failure.

Calls `libraw_open_file` **only** — no unpack, no process — which is why it
costs **1–5 ms**. The UI uses this to populate the EXIF panel immediately.

It transposes `width`/`height` when `flip` is 5 or 6. LibRaw's
`sizes.width`/`height` describe the *unrotated sensor area*, but
`dcraw_process` bakes the camera orientation into its output, so a portrait
frame decodes transposed. Reporting the sensor values made every portrait shot
claim landscape dimensions. `sizes.flip` is populated by `open_file` alone, so
this stays cheap.

#### `RawThumbResult* raw_decode_thumb(const char* path)`

Extracts the camera's embedded preview via `libraw_unpack_thumb`. **Costs
3.5–6.6 ms** measured across the test images — it is a file read and a memcpy,
not a decode. Essentially all of the ~500 ms preview wall-clock time is JPEG
decoding and orientation handling on the Dart side, so that is where to look if
the fast path ever needs to be faster.

Both tested bodies embed a preview at ~99.7% of full resolution — 6048×4024 in a
6064×4040 NEF — so this is near-full quality, not a thumbnail. LibRaw returns the
largest embedded preview; smaller ones (1620×1080, 640×424) are enumerable
through `libraw_data_t.thumbs_list` if a faster first paint is ever wanted.

The JPEG is returned **undecoded**. Flutter decodes JPEG natively, so doing it
here would mean a libjpeg dependency for no benefit. Only `JPEG` and `BITMAP`
previews are handled; other formats return `NULL`, since the full decode is on
its way regardless.

`flip` is returned but **not applied** — the preview is stored unrotated. This
asymmetry with `raw_decode_file` is the single most error-prone thing in the
codebase and is handled in Dart.

Free with `raw_free_thumb`.

#### `void raw_free_result(RawImageResult*)` / `void raw_free_thumb(RawThumbResult*)`

Free the buffer and the struct. Both tolerate `NULL`.

### Verifying it

`/tmp/leak_probe.c` (not in the repo) cycles decode+preview while sampling
`VmRSS`. Last run: flat at 12 MB across six passes of a 33 MP CR3, each
allocating ~98 MB. Worth re-running after touching allocation paths.

---

## 2. The FFI layer — `lib/src/libraw_bindings.dart`

A direct, mechanical mirror of the C structs plus `lookupFunction` calls. No
logic, no error handling, no Flutter imports — so it can be used from a worker
isolate and from `tool/ffi_check.dart`.

```dart
final class RawImageMetaNative extends Struct {
  @Array(64) external Array<Uint8> make;
  @Array(64) external Array<Uint8> model;
  @Float()   external double isoSpeed;
  // …
  @Int32()   external int flip;
}
```

`LibRawBindings.open(soPath)` resolves all five symbols eagerly, so a
mismatched `.so` fails at load with a clear error rather than at first use.

**Field order and type must match the C struct exactly.** There is no compiler
checking this across the boundary. `tool/ffi_check.dart` compares `sizeOf<>()`
against the expected byte counts, which catches the common mistakes: a field
inserted mid-struct, `Int32` where C has `Int64`, a missing `@Array` length.

---

## 3. The Dart wrapper — `lib/src/raw_decoder.dart`

Turns the FFI surface into something the UI can use: `Future`s, `ui.Image`s, and
formatted strings. This is where the awkward parts live.

### Threading

Both decode paths run through `Isolate.run`. The isolate returns **plain bytes**,
never a `ui.Image` — image construction requires the Flutter engine and must
happen on the main isolate.

```
main isolate          worker isolate              main isolate
────────────────────────────────────────────────────────────────
decode(path)  ──────▶ dlopen, decode, free
                      RGB → RGBA
                      Uint8List  ────────────────▶ decodeImageFromPixels
                                                   → ui.Image
```

**Statics do not cross isolate boundaries.** `RawDecoder.libraryPathOverride`
was invisible inside the worker, which silently fell back to the bundle path.
The `.so` path is now resolved on the main isolate and captured into the
closure. Any future configuration read by isolate code needs the same treatment.

### The two paths

`decode()` — full quality. Isolate decodes, converts RGB→RGBA (LibRaw packs 3
bytes per pixel; Flutter needs 4), returns bytes, main isolate builds the image.

`decodePreview()` — fast path, returns `null` when no usable preview exists.
Decodes the JPEG with `ui.instantiateImageCodec`, then normalises orientation.

### Orientation

The one genuinely subtle piece. `dcraw_process` applies the camera's rotation;
the embedded preview does not carry it. A `flip=5` NEF decodes to 4040×6064 but
its preview is a landscape 6048×4024 JPEG. Blitting that directly showed
portrait photos **sideways** for the few seconds before the full decode landed.

`_applyFlip` re-renders through a `PictureRecorder` for LibRaw flip codes 3
(180°), 5 (90° CCW) and 6 (90° CW), disposing the source. Unknown codes are left
alone rather than guessed at.

It is guarded by a runtime check:

```dart
final alreadyRotated =
    image.width == thumb.height && image.height == thumb.width;
if (!alreadyRotated) image = await _applyFlip(image, thumb.flip);
```

Whether Flutter's JPEG codec honours an embedded EXIF orientation tag is not
contractual, so the decoded dimensions are inspected instead of assumed. The
180° case cannot be detected this way — dimensions are unchanged either way —
and is accepted as a known limitation.

`test/preview_orientation_test.dart` pins preview and full decode to the same
orientation across both formats, portrait and landscape.

### `RawMeta` formatting

All display formatting lives here rather than in the widgets, behind one guard:

```dart
static bool _usable(double v) => v.isFinite && v > 0;
```

LibRaw zero-fills the struct on a failed read, and `shutterDisplay` computed
`(1 / shutter).round()`. `1 / 0` is `Infinity`, and `Infinity.round()` **throws
`UnsupportedError`** — so an unreadable file crashed the panel rather than
displaying badly. The ISO row had the same defect via `.toInt()`.

Four of the six fields were being formatted inline in the widget, which is how
three of them came to share one latent crash. Consolidating them means the guard
cannot be forgotten when the next field is added. Unusable values render as `—`.

---

## 4. The UI — `lib/src/viewer_screen.dart`

A single stateful screen. `main.dart` only wires up `MaterialApp` with a dark
theme.

```
Column
├── toolbar (48px)   Open RAW · zoom · fit · 1:1 · status
└── Expanded
    └── Row
        ├── Expanded → canvas   GestureDetector › ClipRect › SizedBox.expand › CustomPaint
        └── EXIF panel (220px)  file name, camera, resolution, ISO, shutter, aperture, focal
```

### Rendering

`_ImagePainter` draws the image into a destination rect derived from `_scale`
and `_offset`, centred in the canvas. `_scale` maps image pixels to logical
screen pixels, so 1.0 is exactly 1:1.

**`SizedBox.expand` around the `CustomPaint` is load-bearing.** A childless
`CustomPaint` takes its size from the `size` property, which defaults to
`Size.zero`, and `Row`'s default `crossAxisAlignment.center` passes *loose*
vertical constraints — so it collapsed to `Size(580, 0)`: full width, zero
height. The image decoded correctly and was painted into a box with no height.
`test/canvas_layout_test.dart` pins this.

### Zoom

`fitScaleFor(image, canvas)` is a free function, not a method, so it can be
tested without a widget tree. It takes the smaller of the two axis ratios, so
the whole frame is visible.

The canvas is measured through a `GlobalKey` and `findRenderObject()` rather
than tracked in state, because its size is only known after layout.

Scale is clamped to 0.01–20.0. The floor matters: a 6984 px image in a 1146 px
canvas fits at ~0.16, so the original 0.1 floor would have refused to fit in a
smaller window.

### Loading sequence

```
_decodeFile(path)
  ├── ++_requestId, clear state, dispose old image
  ├── start full decode (not awaited yet)
  ├── await preview  → show it, fit to window        ~0.5 s
  └── await full     → replace image, keep user zoom  ~3.5 s
```

The full decode is started *before* awaiting the preview so the two overlap.

Fitting happens in `addPostFrameCallback`, not in the `setState` that delivers
the image: `_canvasKey` hangs off a widget that only exists once `_image` is
non-null, so the canvas is not measurable at that moment. A `LayoutBuilder`
would avoid the wait, but its builder runs during layout — after the EXIF panel
has been built — so the sidebar would show a stale zoom percentage for a frame.

Refitting is deliberately skipped when the full decode replaces a preview, so a
user who has already zoomed does not have it thrown away.

### Image lifetime

`ui.Image` holds GPU memory that garbage collection will not reclaim promptly. A
33 MP frame is ~130 MB of RGBA, and each open produces two.

- Every swap goes through `_replaceImage()`, which disposes the outgoing image.
- `State.dispose()` releases the last one.
- `_requestId` guards against a slow decode from a previous file landing after
  the user opened a different one; superseded images are disposed, not shown.
- Every path that does not adopt an image disposes it explicitly.

---

## Known gaps

- **No error detail.** The C layer returns `NULL` for every failure, so the UI
  can only say "failed to decode". Returning the LibRaw error code and mapping
  it through `libraw_strerror` would fix this.
- **16-bit output is dead code.** `output_bps` is hardcoded to 8; the `bits`
  field is carried through but never anything else, and the Dart conversion
  assumes 8.
- **`colors == 4` is untested.** LibRaw returns 3 for every file tried, so that
  branch of the RGB→RGBA conversion has never executed.
- **180° preview rotation is undetectable.** See *Orientation* above.
- **No caching.** Reopening a file decodes it again from scratch.
