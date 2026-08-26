# Focus point data in Canon and Nikon RAW files

Research notes for Phase 5 of `PLAN.md` — opening an image at 1:1 centred on
where the camera focused.

Everything marked **verified** was measured against the files in `test-images/`
(Nikon Z 6_2 NEF, Canon EOS R7 CR3) using LibRaw 0.22.2. Everything marked
**unverified** comes from documentation and still needs confirming.

---

## Summary

Both vendors store AF information in the **MakerNote** IFD, not in standard
EXIF. There is no cross-vendor standard: the tag numbers, layouts, coordinate
origins and sign conventions all differ.

| | Canon EOS R7 | Nikon Z 6_2 |
|---|---|---|
| MakerNote tag | `0x0026` (AFInfo2) | `0x00b7` (AFInfo2) |
| Blob length | 5472 bytes | 56 bytes |
| AF points described | 651 | 1 area |
| Origin | **image centre**, signed | **top-left**, unsigned |
| Coordinate space | `AFImageWidth` × `AFImageHeight` | same |
| Y direction | **up** (confirmed) | downward |

**Both are readable without a MakerNote parser of our own.** LibRaw already
extracts these blobs; see *Getting at the data* below.

---

## Getting at the data — LibRaw exposes it (verified)

LibRaw does not decode AF points into named fields, but it does lift the raw
MakerNote blob out for us:

```c
// libraw_types.h
typedef struct {
  unsigned AFInfoData_tag;      // 0x0026 Canon, 0x00b7 Nikon
  short    AFInfoData_order;    // byte order marker
  unsigned AFInfoData_version;
  unsigned AFInfoData_length;
  uchar   *AFInfoData;          // the blob
} libraw_afinfo_item_t;

// imgdata.makernotes.common
libraw_afinfo_item_t afdata[LIBRAW_AFDATA_MAXCOUNT];  // max 4
int afcount;
```

Populated by `libraw_open_file` alone — no unpack, no process — so reading it
stays in the same 1–5 ms budget as the rest of the metadata path.

Both test cameras yield `afcount == 1`. The vendor structs
(`makernotes.canon`, `makernotes.nikon`) contain **no** usable AF point fields —
Canon's has only `AFMicroAdjMode`/`AFMicroAdjValue`. The blob is the route.

This makes option (a) in PLAN 5.4 viable: parse the blob in our C wrapper. No
MakerNote IFD walking, and no `exiftool` runtime dependency.

---

## Canon — tag `0x0026`, AFInfo2

### Layout (verified against the R7 files)

A flat array of 16-bit words, little-endian. Variable-length sections are sized
by `NumAFPoints`.

| Word | Byte | Field | Format |
|---|---|---|---|
| 0 | 0 | `AFInfoSize` | int16u |
| 1 | 2 | `AFAreaMode` | int16u |
| 2 | 4 | `NumAFPoints` | int16u |
| 3 | 6 | `ValidAFPoints` | int16u |
| 4 | 8 | `CanonImageWidth` | int16u |
| 5 | 10 | `CanonImageHeight` | int16u |
| 6 | 12 | `AFImageWidth` | int16u |
| 7 | 14 | `AFImageHeight` | int16u |
| 8 | 16 | `AFAreaWidths[NumAFPoints]` | int16u |
| … | | `AFAreaHeights[NumAFPoints]` | int16u |
| … | | `AFAreaXPositions[NumAFPoints]` | **int16s** |
| … | | `AFAreaYPositions[NumAFPoints]` | **int16s** |
| … | | `AFPointsInFocus` | bitmask, `ceil(N/16)` words |
| … | | `AFPointsSelected` | bitmask, `ceil(N/16)` words |
| … | | `AFPointsUnusable` | bitmask, `ceil(N/16)` words |

The bitmasks are little-endian per word: point *i* is bit `i % 16` of word
`i / 16`. Iterating `AFPointsInFocus` gives the points that actually achieved
focus — usually far fewer than `NumAFPoints`.

### Coordinate system

Positions are the **centre of the AF area**, with the **origin at the centre of
the image**, in a space measured by `AFImageWidth` × `AFImageHeight`. Values are
**signed**; left of centre is negative.

### Y direction — resolved: positive Y is UP

```
x_pixels = AFAreaXPosition + AFImageWidth  / 2
y_pixels = AFImageHeight / 2 - AFAreaYPosition       ← note the subtraction
```

**Confirmed 2026-08-26 for the EOS R7** by rendering the marker and checking it
against the intended subjects. This had to be settled by observation because two
references disagreed:

- One stated positive Y is **up** for EOS and down for PowerShot. ✅ **Correct.**
- ExifTool's tag table as rendered on the chiark mirror stated EOS uses origin
  at top with Y increasing *downward*. ❌ Contradicted by observation — most
  likely an artefact of that page's rendering rather than ExifTool itself.

Getting this wrong mirrors the focus point across the horizontal axis. For an
off-centre subject that is badly wrong but still *plausible-looking*, so it does
not announce itself — which is why `FocusPoint.canonPositiveYIsUp` remains a
switch rather than being folded into a constant. PowerShot bodies are documented
to use the opposite convention, and other EOS generations are untested.

Both readings for `20250803_A0A8111.CR3`, for reference:

```
raw = (-783, -423)   area 163x163   AFImage 6960x4640
  +Y up    ->  x=2697  y=2743      ← confirmed correct
  +Y down  ->  x=2697  y=1897
```

### Verified sample

```
20250803_A0A8111.CR3   AFAreaMode=22  NumAFPoints=651  ValidAFPoints=1
                       CanonImage=6960x4640  AFImage=6960x4640
                       in-focus #0  raw=(-783,-423)  area 163x163

20250803_A0A8129.CR3   in-focus #0  raw=(-241, 99)   area 163x163
```

`ValidAFPoints=1` on both: the R7's subject tracking reports a single resolved
area, not a grid of lit points, despite describing all 651 positions.

---

## Nikon — tag `0x00b7`, AFInfo2

### Layout (verified against the Z 6_2 files)

56-byte blob. **Offsets below are into the blob as LibRaw presents it**, which
appears to exclude the 4-byte version header that ExifTool counts — LibRaw
reports that separately as `AFInfoData_version = 301`. If cross-referencing
ExifTool's tables, expect a 4-byte shift.

| Byte | Field | Format | Observed |
|---|---|---|---|
| 0 | (ContrastDetectAF?) | int8u | `0x02` |
| 1 | (AFAreaMode?) | int8u | `0xc1` |
| 2–37 | zero in all samples | | `00` |
| 38 | `AFImageWidth` | int16u | 6048 |
| 40 | `AFImageHeight` | int16u | 4024 |
| 42 | `AFAreaXPosition` | int16u | varies |
| 44 | `AFAreaYPosition` | int16u | varies |
| 46 | `AFAreaWidth` | int16u | 285 |
| 48 | `AFAreaHeight` | int16u | 308 |
| 50 | (in-focus flag?) | int16u | 1 |

Bytes 0–1 and 50 are labelled speculatively; they were consistent across all
seven files, so their meaning is inferred, not established.

### Coordinate system

Origin **top-left**, **unsigned**, giving the **centre of the AF area** in a
space measured by `AFImageWidth` × `AFImageHeight`. No sign handling and no Y
inversion needed — simpler than Canon.

```
x_pixels = AFAreaXPosition
y_pixels = AFAreaYPosition
```

### Verified samples

Offsets 42/44 vary per image while 38/40/46/48 stay fixed, which is what
confirms they are the AF position rather than constants:

| File | X | Y | flip |
|---|---|---|---|
| DSC_1436.NEF | 4068 | 2864 | 0 |
| DSC_1437.NEF | 4329 | 2296 | 0 |
| DSC_1438.NEF | 4329 | 2296 | 0 |
| DSC_1439.NEF | 4329 | 2296 | 0 |
| DSC_1440.NEF | 3807 | 2864 | 0 |
| DSC_1441.NEF | 2241 | 1728 | **5** |
| DSC_1442.NEF | 2241 | 1728 | **5** |

---

## Mapping onto the displayed image

Two transforms are needed, and both have already caught this codebase out
elsewhere (see PLAN 2.7 and 3.1).

### 1. Scale — AF space is not the decoded image

`AFImageWidth`/`AFImageHeight` describe a slightly *smaller* image than the full
decode:

| | AFImage | Decoded | Ratio |
|---|---|---|---|
| Canon R7 | 6960 × 4640 | 6984 × 4660 | 1.0034 × 1.0043 |
| Nikon Z 6_2 | 6048 × 4024 | 6064 × 4040 | 1.0026 × 1.0040 |

Small, but not negligible: 0.35% of 6984 px is ~24 px, roughly 15% of the R7's
163 px AF box. Scale explicitly:

```
x_image = x_af * (decodedWidth  / AFImageWidth)
y_image = y_af * (decodedHeight / AFImageHeight)
```

**Both AFImage sizes exactly match that body's embedded JPEG preview** (6960×4640
and 6048×4024 respectively, per `raw_decode_thumb`). The AF coordinate space is
the preview's space, which is a useful consistency check and means AF
coordinates can be overlaid on the preview with no scaling at all.

### 2. Orientation — AF coordinates are recorded unrotated

`DSC_1441.NEF` and `DSC_1442.NEF` have `flip=5` (90° CCW) yet report
`AFImage = 6048 × 4024`, a *landscape* space, with X=2241 within a 6048-wide
frame. So AF coordinates are recorded against the **unrotated sensor**, exactly
like the embedded preview and unlike `dcraw_process` output.

The same `flip` rotation applied to previews must therefore be applied to the
focus point. For `flip == 5` (90° CCW):

```
x_rot = y_af
y_rot = AFImageWidth - x_af
```

Verify against a portrait frame before trusting it — the direction is easy to
invert, and PLAN 5.8 exists for this.

---

## Open questions

1. **Nikon bytes 0–1 and 50.** Inferred, not established. Byte 50 is presumably
   an in-focus/valid flag; if it can be 0, it must gate the feature.
2. **What happens with no AF data?** Manual focus, adapted lenses and older
   bodies may omit the tag or report zeroes. `afcount == 0` must fall back to
   fit-to-window silently (PLAN 5.10).
3. **Multiple in-focus points.** Canon can flag several. Centre on the centroid,
   or the first? Unresolved.
4. **`AFAreaMode = 22`** on every R7 sample — meaning unknown, and worth
   decoding since it likely distinguishes subject tracking from single-point.
5. **Other vendors.** Sony, Fujifilm and others use different tags entirely;
   LibRaw's `afdata` comment lists Sony's `0x2020`/`0x2022`/`0x940e`. Out of
   scope until Canon and Nikon work.

---

## Cross-checking with ExifTool

ExifTool is the reference implementation for all of this. It is not installed
here; `sudo dnf install -y perl-Image-ExifTool` would allow verifying the parses
above against an independent implementation:

```bash
exiftool -a -G1 -s -AFInfo2 -AFAreaXPositions -AFAreaYPositions \
         -AFPointsInFocus -AFImageWidth -AFImageHeight test-images/*.CR3
```

The Canon Y direction has since been settled by observation, but this would
still be worth doing to confirm the speculative Nikon fields.

## Sources

- [ExifTool Canon tag names (chiark mirror)](https://www.chiark.greenend.org.uk/doc/libimage-exiftool-perl/html/TagNames/Canon.html)
- [ExifTool Nikon tag names (chiark mirror)](https://www.chiark.greenend.org.uk/doc/libimage-exiftool-perl/html/TagNames/Nikon.html)
- [Image::ExifTool::Canon on MetaCPAN](https://metacpan.org/pod/Image::ExifTool::Canon)
- [exiftool/Nikon.pm source](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Nikon.pm)
- [Exiv2 #981 — Canon AFInfo seems misinterpreted](https://github.com/Exiv2/exiv2/issues/981)
- [Exiv2 #1543 — Canon AFInfo rotation](https://github.com/Exiv2/exiv2/issues/1543)
- [Exiv2 #646 — Nikon D850 AF tags](https://github.com/Exiv2/exiv2/issues/646)
- [Exiv2 Nikon MakerNote tag reference](https://exiv2.org/tags-nikon.html)
- LibRaw 0.22.2 headers, `/usr/include/libraw/libraw_types.h`
