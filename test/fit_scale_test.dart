// Fit-to-window must leave BOTH axes no larger than the viewing area.

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/viewer_screen.dart';

void main() {
  // Real dimensions from the test images, in a canvas roughly the size of the
  // app's image area on a 1366px-wide window.
  const canvas = Size(1146, 645);

  void expectFitsInside(Size image, Size canvasSize) {
    final s = fitScaleFor(image, canvasSize);
    expect(image.width * s, lessThanOrEqualTo(canvasSize.width + 0.001),
        reason: 'width still overflows at scale $s');
    expect(image.height * s, lessThanOrEqualTo(canvasSize.height + 0.001),
        reason: 'height still overflows at scale $s');
  }

  test('landscape image fits on both axes (Canon EOS R7)', () {
    expectFitsInside(const Size(6984, 4660), canvas);
  });

  test('portrait image fits on both axes (rotated Nikon Z 6_2)', () {
    expectFitsInside(const Size(4040, 6064), canvas);
  });

  test('is limited by the tighter axis, not the looser one', () {
    // A very wide image must be constrained by width.
    expect(fitScaleFor(const Size(2000, 100), const Size(1000, 1000)), 0.5);
    // A very tall one by height.
    expect(fitScaleFor(const Size(100, 2000), const Size(1000, 1000)), 0.5);
  });

  test('square image in a square canvas fills it exactly', () {
    expect(fitScaleFor(const Size(500, 500), const Size(250, 250)), 0.5);
  });
}
