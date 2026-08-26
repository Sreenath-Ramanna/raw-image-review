// Focus point coordinate mapping.
//
// Three transforms stack here: vendor origin/sign, AF-space -> decoded-image
// scaling, and rotation. Each is individually plausible when wrong, so they are
// tested separately and together.

import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/focus_point.dart';

FocusPoint canon({
  int x = 0,
  int y = 0,
  int w = 163,
  int h = 163,
  int afW = 6960,
  int afH = 4640,
  int flip = 0,
}) =>
    FocusPoint(
      vendor: FocusPoint.vendorCanon,
      rawX: x,
      rawY: y,
      areaWidth: w,
      areaHeight: h,
      afImageWidth: afW,
      afImageHeight: afH,
      flip: flip,
      pointsInFocus: 1,
    );

FocusPoint nikon({
  int x = 0,
  int y = 0,
  int w = 285,
  int h = 308,
  int afW = 6048,
  int afH = 4024,
  int flip = 0,
}) =>
    FocusPoint(
      vendor: FocusPoint.vendorNikon,
      rawX: x,
      rawY: y,
      areaWidth: w,
      areaHeight: h,
      afImageWidth: afW,
      afImageHeight: afH,
      flip: flip,
      pointsInFocus: 1,
    );

void main() {
  // Restore the shipped default after tests that flip it.
  tearDown(() => FocusPoint.canonPositiveYIsUp = true);

  group('Canon — origin at image centre', () {
    test('a zero position maps to the image centre', () {
      final area = canon(x: 0, y: 0).areaInImage(6960, 4640)!;
      expect(area.centerX, closeTo(3480, 0.01));
      expect(area.centerY, closeTo(2320, 0.01));
    });

    test('positive x is to the right of centre', () {
      final area = canon(x: 1000).areaInImage(6960, 4640)!;
      expect(area.centerX, closeTo(4480, 0.01));
    });

    test('canonPositiveYIsUp mirrors the point across the centre line', () {
      FocusPoint.canonPositiveYIsUp = true;
      final up = canon(y: 500).areaInImage(6960, 4640)!.centerY;

      FocusPoint.canonPositiveYIsUp = false;
      final down = canon(y: 500).areaInImage(6960, 4640)!.centerY;

      expect(up, closeTo(1820, 0.01)); // 2320 - 500
      expect(down, closeTo(2820, 0.01)); // 2320 + 500
      // Equidistant from the centre line, on opposite sides.
      expect((2320 - up), closeTo(down - 2320, 0.01));
    });

    test('the real A0A8111 point resolves as documented', () {
      // raw (-783,-423) in a 6960x4640 AF space.
      FocusPoint.canonPositiveYIsUp = true;
      final up = canon(x: -783, y: -423).areaInImage(6960, 4640)!;
      expect(up.centerX, closeTo(2697, 0.5));
      expect(up.centerY, closeTo(2743, 0.5));

      FocusPoint.canonPositiveYIsUp = false;
      final down = canon(x: -783, y: -423).areaInImage(6960, 4640)!;
      expect(down.centerY, closeTo(1897, 0.5));
    });
  });

  group('Nikon — origin top-left', () {
    test('maps straight through when AF space matches the image', () {
      final area = nikon(x: 4068, y: 2864).areaInImage(6048, 4024)!;
      expect(area.centerX, closeTo(4068, 0.01));
      expect(area.centerY, closeTo(2864, 0.01));
    });

    test('is unaffected by the Canon Y switch', () {
      FocusPoint.canonPositiveYIsUp = false;
      final area = nikon(x: 4068, y: 2864).areaInImage(6048, 4024)!;
      expect(area.centerY, closeTo(2864, 0.01));
    });
  });

  group('scaling from AF space to the decoded image', () {
    test('scales by the ratio of decoded to AF dimensions', () {
      // Real Nikon case: AF space 6048x4024, decode 6064x4040. Each axis
      // scales independently — the ratios differ slightly.
      final area = nikon(x: 3024, y: 2012).areaInImage(6064, 4040)!;
      expect(area.centerX, closeTo(3024 * (6064 / 6048), 0.01));
      expect(area.centerY, closeTo(2012 * (4040 / 4024), 0.01));
    });

    test('the area size scales too', () {
      final area = nikon(x: 3024, y: 2012, w: 285, h: 308)
          .areaInImage(6048 * 2, 4024 * 2)!;
      expect(area.width, closeTo(570, 0.01));
      expect(area.height, closeTo(616, 0.01));
    });
  });

  group('rotation — AF coordinates are recorded unrotated', () {
    // A portrait Z 6_2 frame: AF space is landscape 6048x4024, the decoded
    // image is portrait 4040x6064.
    test('flip=5 (90 CCW) rotates the point with the image', () {
      final area = nikon(x: 2241, y: 1728, flip: 5).areaInImage(4040, 6064)!;
      // Unrotated space is 6064x4040; x scales by 6064/6048, y by 4040/4024.
      final px = 2241 * (6064 / 6048);
      final py = 1728 * (4040 / 4024);
      expect(area.centerX, closeTo(py, 0.01));
      expect(area.centerY, closeTo(6064 - px, 0.01));
    });

    test('flip=5 swaps the area width and height', () {
      final area = nikon(x: 2241, y: 1728, w: 285, h: 308, flip: 5)
          .areaInImage(4040, 6064)!;
      expect(area.width, greaterThan(area.height));
    });

    test('a rotated point stays inside the image bounds', () {
      for (final flip in [0, 3, 5, 6]) {
        final portrait = flip == 5 || flip == 6;
        final w = portrait ? 4040 : 6064;
        final h = portrait ? 6064 : 4040;
        final area = nikon(x: 2241, y: 1728, flip: flip).areaInImage(w, h)!;
        expect(area.centerX, inInclusiveRange(0, w.toDouble()),
            reason: 'flip=$flip put x outside the image');
        expect(area.centerY, inInclusiveRange(0, h.toDouble()),
            reason: 'flip=$flip put y outside the image');
      }
    });

    test('flip=3 (180) reflects through the centre', () {
      final upright = nikon(x: 1000, y: 800).areaInImage(6048, 4024)!;
      final flipped = nikon(x: 1000, y: 800, flip: 3).areaInImage(6048, 4024)!;
      expect(flipped.centerX, closeTo(6048 - upright.centerX, 0.01));
      expect(flipped.centerY, closeTo(4024 - upright.centerY, 0.01));
    });
  });

  group('unusable data', () {
    test('returns null when the AF space is empty', () {
      expect(nikon(afW: 0).areaInImage(6048, 4024), isNull);
      expect(nikon(afH: 0).areaInImage(6048, 4024), isNull);
    });

    test('returns null for a zero-sized image', () {
      expect(nikon(x: 100, y: 100).areaInImage(0, 0), isNull);
    });
  });
}
