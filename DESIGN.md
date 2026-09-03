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
│  libraw_images_api.so    raw_decode_file · raw_read_meta …  │  C, separate repo
├─────────────────────────────────────────────────────────────┤
│  LibRaw 0.22.2                                              │  system library
└─────────────────────────────────────────────────────────────┘
```

The split exists because decoding a RAW is seconds of CPU work that must not
touch the UI thread, and because LibRaw is a C library with no Dart equivalent.
Everything below `raw_decoder.dart` is deliberately framework-free so it can run
inside a worker isolate.

---

## 1. The C layer — `raw_images_api`

Extracted into its own repository so that the decoding and processing can grow
without dragging a Flutter app behind it. Full documentation is in
`../raw_images_api/API.md`; what matters here is the shape of the seam.

The viewer binds the **legacy `raw_*` ABI** that library still exports — the
one this repo's `libraw_bindings.dart` was written against — rather than the
newer `ria_*` API. Four entry points:

| symbol | cost | what the viewer does with it |
|---|---|---|
| `raw_read_meta` | 1–5 ms | fills the EXIF panel immediately |
| `raw_read_focus` | 1–5 ms | opens the frame 1:1 on the focus point |
| `raw_decode_thumb` | 3–7 ms | the embedded JPEG, on screen in ~0.5 s |
| `raw_decode_file` | 1.5–3 s | the full demosaic, on demand |

Three properties of that ABI shape everything above it:

- **Every function returns a pointer or an int, never a struct by value**, and
  every allocation has a matching free function. Struct-return ABI is the
  fiddliest thing to get right across FFI.
- **`NULL` means failure, with no detail.** The `ria_*` API this now sits on
  does return typed errors; adopting them means rewriting
  `libraw_bindings.dart` against the newer structs. See *Known gaps*.
- **`raw_decode_file` returns pixels with the camera rotation already applied;
  `raw_decode_thumb` does not.** This asymmetry is the single most error-prone
  thing in the codebase and is handled in Dart — see *Orientation* below.

`tool/ffi_check.dart` asserts the Dart struct sizes against the C ones
(`RawImageResult` 32 bytes, `RawImageMeta` 156) at startup. That check is the
cheapest possible guard against layout drift, which otherwise shows up as
plausible-looking garbage rather than a crash.

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

`LibRawBindings.open(soPath)` resolves all six symbols eagerly, so a
mismatched `.so` fails at load with a clear error rather than at first use.

**Field order and type must match `raw_images_api_legacy.h` exactly.** There
is no compiler checking this across the boundary. `tool/ffi_check.dart` compares `sizeOf<>()`
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

### Folder navigation

`rawFilesIn(Directory)` is a free function for the same reason `fitScaleFor` is:
it can be tested without a widget tree. It matches extensions
case-insensitively — cameras write `.NEF` and `.CR3` in upper case, so a naive
lowercase comparison finds nothing — and does not recurse, because a shoot
folder is the unit people browse.

Keyboard handling sits in a `Focus` wrapping the whole `Scaffold`, taking
`KeyDownEvent` only. Honouring auto-repeat would queue a multi-second decode for
every repeat while an arrow key is held. Focus is explicitly reclaimed after the
directory picker closes, since the picker takes it and the arrow keys would
otherwise be dead until the user clicked the window.

Rapid navigation is safe rather than optimal: several decodes may be in flight
at once, and `_requestId` ensures only the newest is displayed while the rest
are disposed on arrival.

### Focus point

`lib/src/focus_point.dart` holds the geometry and, like `libraw_bindings.dart`,
is deliberately free of `dart:ui` — so `tool/ffi_check.dart` can use it and the
maths is testable without a Flutter binding. It returns a plain `FocusArea`
which the widget layer converts to a `Rect`.

The C wrapper returns the vendor's **raw** values rather than a resolved pixel
position. Canon and Nikon disagree on origin and sign, so interpretation belongs
where it can be switched and tested without rebuilding the native library.

Three transforms stack, each individually plausible when wrong:

1. **Vendor coordinates → top-left origin.** Canon measures from the image
   centre with signed values; Nikon from the top-left, unsigned.
2. **AF space → decoded image.** AF coordinates are relative to
   `AFImageWidth`/`AFImageHeight`, which match the *embedded preview*, not the
   full decode — about 0.35% smaller. Each axis scales independently.
3. **Rotation.** AF coordinates are recorded against the unrotated sensor, so
   the same flip applied to previews applies here. This mirrors
   `RawDecoder._applyFlip` exactly; if one changes, so must the other.

`FocusPoint.canonPositiveYIsUp` is confirmed `true` for EOS bodies, settled by
observation after the references contradicted each other. It stays a switch
rather than a constant because PowerShot bodies use the opposite convention and
other EOS generations are untested — and because a wrong choice mirrors the
point across the horizontal axis, which looks plausible rather than broken. See
FOCUS_POINTS.md.

### Preloading

Stepping between images used to cost a full preview decode, ~0.5 s. The
previous and next files are now decoded in the background while the user looks
at the current one, so a step in either direction is instant.

`preloadWindow()` is a free function — testable without a widget tree, like
`fitScaleFor` and `indexAfterRemoval` — returning the indices to keep decoded.
Anything outside that window is evicted and disposed.

The subtle part is **ownership**. `_image` may point either at a cached preview,
which the cache owns and may outlive the current view, or at a full decode,
which the widget owns. `_imageFromCache` tracks which, and `_replaceImage`
disposes only in the second case. Eviction has a matching rule: if the image
being evicted is the one on screen, ownership transfers to the widget rather
than disposing something the painter is about to read.

Memory is the real cost. Previews are ~99.7% of full resolution, so each cached
`ui.Image` is 97 MB (24 MP) to 129 MB (33 MP), and a three-entry window plus the
current full decode sits around 400–500 MB. Caching the JPEG *bytes* instead
would be almost free but pointless: extraction is only ~5 ms of the ~500 ms, and
the decode is the expensive part, so only decoded images are worth holding.

Preloading starts only once the current image is on screen — kicking it off
earlier would put two more decodes in flight competing with the one the user is
actually waiting for.

### Deleting

`moveToTrash()` shells out to `gio trash` rather than calling `File.delete()`.
This is a culling tool aimed at original camera files, so recoverability is
worth more than the saved process spawn; `gio` ships with glib2, which GTK
already requires. Its stderr is surfaced verbatim, which matters because it
refuses tmpfs and other system-internal mounts with a specific message.

`indexAfterRemoval()` is a free function, testable without a widget tree. It
keeps the same index after a removal, which lands on what *was* the next image
so culling flows forward, and steps back only when the last entry goes. When the
list empties, `_requestId` is bumped so an in-flight decode is discarded rather
than painting over the empty state.

### Loading sequence

```
_decodeFile(path)
  ├── ++_requestId, clear state, dispose old image
  ├── start full decode (not awaited yet)
  ├── await preview  → show it, 1:1 on focus point   ~0.5 s
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

- **No error detail.** The legacy ABI returns `NULL` for every failure, so the
  UI can only say "failed to decode". `raw_images_api` reports typed errors
  through `ria_status`; using them means porting `libraw_bindings.dart` to the
  `ria_*` structs.
- **16-bit output is unused.** The library decodes to 16 bits on request, but
  this viewer pins 8 through the legacy ABI and the Dart side assumes it.
- **The processing operations are unused.** `raw_images_api` can adjust
  exposure, contrast and colour, resize and sharpen; none of that is wired to
  the UI yet.
- **`colors == 4` is untested.** LibRaw returns 3 for every file tried, so that
  branch of the RGB→RGBA conversion has never executed.
- **180° preview rotation is undetectable.** See *Orientation* above.
- **No caching.** Reopening a file decodes it again from scratch.
