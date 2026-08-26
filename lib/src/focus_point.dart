// Focus point geometry.
//
// Deliberately free of dart:ui so it can be used from plain-Dart tooling
// (tool/ffi_check.dart) and tested without a Flutter binding — the same
// reasoning that keeps libraw_bindings.dart framework-free.

/// An axis-aligned AF area in decoded-image pixel coordinates.
class FocusArea {
  final double centerX;
  final double centerY;
  final double width;
  final double height;

  const FocusArea({
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
  });

  double get left => centerX - width / 2;
  double get top => centerY - height / 2;

  @override
  String toString() => 'FocusArea(centre: (${centerX.toStringAsFixed(1)}, '
      '${centerY.toStringAsFixed(1)}), ${width.toStringAsFixed(1)}x'
      '${height.toStringAsFixed(1)})';
}

/// Where the camera focused, as recorded in the MakerNote.
///
/// Holds the vendor's raw values; [areaInImage] resolves them into decoded
/// image pixels. Canon and Nikon disagree on origin and sign, and Canon's Y
/// direction is documented inconsistently — see FOCUS_POINTS.md.
class FocusPoint {
  static const int vendorNone = 0;
  static const int vendorCanon = 1;
  static const int vendorNikon = 2;

  /// Whether Canon EOS bodies measure `AFAreaYPositions` upward from the image
  /// centre.
  ///
  /// **`true` is confirmed correct for EOS**, verified 2026-08-26 against real
  /// EOS R7 frames by checking the marker against the intended subjects. The
  /// references disagreed on this, so it was settled by observation.
  ///
  /// Kept as a switch because PowerShot bodies are documented to use the
  /// opposite convention, and other EOS generations are untested. Flipping it
  /// mirrors the point across the horizontal axis — a wrong setting looks
  /// plausible rather than broken, so change it only on visual evidence.
  ///
  /// Nikon is unaffected — its origin is the top-left corner and unambiguous.
  static bool canonPositiveYIsUp = true;

  final int vendor;
  final int rawX;
  final int rawY;
  final int areaWidth;
  final int areaHeight;
  final int afImageWidth;
  final int afImageHeight;

  /// LibRaw orientation. AF coordinates are recorded against the *unrotated*
  /// sensor, so this has to be applied — as with the embedded preview.
  final int flip;

  /// How many AF points reported focus. Canon can report several, in which
  /// case the wrapper averages them.
  final int pointsInFocus;

  const FocusPoint({
    required this.vendor,
    required this.rawX,
    required this.rawY,
    required this.areaWidth,
    required this.areaHeight,
    required this.afImageWidth,
    required this.afImageHeight,
    required this.flip,
    required this.pointsInFocus,
  });

  /// The AF area in decoded-image pixel coordinates, or null if unusable.
  ///
  /// [imageWidth]/[imageHeight] are the dimensions of the decoded image, i.e.
  /// already rotated by `dcraw_process`.
  FocusArea? areaInImage(int imageWidth, int imageHeight) {
    if (afImageWidth <= 0 || afImageHeight <= 0) return null;
    if (imageWidth <= 0 || imageHeight <= 0) return null;

    // 1. Vendor coordinates → unrotated AF space with the origin top-left.
    final double xAf;
    final double yAf;
    if (vendor == vendorCanon) {
      // Origin at image centre, signed, positive x to the right.
      xAf = rawX + afImageWidth / 2;
      yAf = canonPositiveYIsUp
          ? afImageHeight / 2 - rawY
          : afImageHeight / 2 + rawY;
    } else {
      // Nikon: already top-left and unsigned.
      xAf = rawX.toDouble();
      yAf = rawY.toDouble();
    }

    // 2. Scale into the decoded image. AF space is slightly smaller than the
    //    decode (it matches the embedded preview), so this is not a no-op.
    //    imageWidth/Height are post-rotation, so undo that for quarter turns.
    final quarterTurn = flip == 5 || flip == 6;
    final unrotatedW = (quarterTurn ? imageHeight : imageWidth).toDouble();
    final unrotatedH = (quarterTurn ? imageWidth : imageHeight).toDouble();

    final sx = unrotatedW / afImageWidth;
    final sy = unrotatedH / afImageHeight;

    final px = xAf * sx;
    final py = yAf * sy;
    final w = areaWidth * sx;
    final h = areaHeight * sy;

    // 3. Rotate to match the decoded image. Mirrors RawDecoder._applyFlip so
    //    the marker tracks the pixels it describes.
    final double cx;
    final double cy;
    final double rw;
    final double rh;
    switch (flip) {
      case 5: // 90° CCW
        cx = py;
        cy = unrotatedW - px;
        rw = h;
        rh = w;
      case 6: // 90° CW
        cx = unrotatedH - py;
        cy = px;
        rw = h;
        rh = w;
      case 3: // 180°
        cx = unrotatedW - px;
        cy = unrotatedH - py;
        rw = w;
        rh = h;
      default:
        cx = px;
        cy = py;
        rw = w;
        rh = h;
    }

    return FocusArea(centerX: cx, centerY: cy, width: rw, height: rh);
  }

  @override
  String toString() => 'FocusPoint(vendor: $vendor, raw: ($rawX, $rawY), '
      'area: ${areaWidth}x$areaHeight, afImage: ${afImageWidth}x'
      '$afImageHeight, flip: $flip, inFocus: $pointsInFocus)';
}
