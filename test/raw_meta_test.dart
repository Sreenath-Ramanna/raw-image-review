// RawMeta formatting, including the values LibRaw produces when it cannot
// read a file: it zero-fills the struct, so every getter has to survive zero.

import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/raw_decoder.dart';

RawMeta meta({
  String make = 'Nikon',
  String model = 'Z 6_2',
  double isoSpeed = 800,
  double shutter = 0.00125,
  double aperture = 8,
  double focalLen = 40,
  int width = 6064,
  int height = 4040,
  int flip = 0,
}) =>
    RawMeta(
      make: make,
      model: model,
      isoSpeed: isoSpeed,
      shutter: shutter,
      aperture: aperture,
      focalLen: focalLen,
      width: width,
      height: height,
      flip: flip,
    );

void main() {
  group('shutterDisplay', () {
    test('formats fractional exposures as a reciprocal', () {
      expect(meta(shutter: 0.00125).shutterDisplay, '1/800s');
      expect(meta(shutter: 0.000625).shutterDisplay, '1/1600s');
    });

    test('formats exposures of a second or longer in seconds', () {
      expect(meta(shutter: 1).shutterDisplay, '1s');
      expect(meta(shutter: 30).shutterDisplay, '30s');
    });

    test('does not divide by zero', () {
      // 1/0 is Infinity, and Infinity.round() throws UnsupportedError, so this
      // used to take the whole EXIF panel down rather than display badly.
      expect(meta(shutter: 0).shutterDisplay, RawMeta.unknown);
    });

    test('rejects negative and non-finite values', () {
      expect(meta(shutter: -1).shutterDisplay, RawMeta.unknown);
      expect(meta(shutter: double.nan).shutterDisplay, RawMeta.unknown);
      expect(meta(shutter: double.infinity).shutterDisplay, RawMeta.unknown);
    });
  });

  group('other fields survive a zero-filled struct', () {
    test('aperture', () {
      expect(meta(aperture: 6.3).apertureDisplay, 'f/6.3');
      expect(meta(aperture: 0).apertureDisplay, RawMeta.unknown);
      expect(meta(aperture: double.nan).apertureDisplay, RawMeta.unknown);
    });

    test('iso', () {
      expect(meta(isoSpeed: 1000).isoDisplay, '1000');
      expect(meta(isoSpeed: 0).isoDisplay, RawMeta.unknown);
      // .toInt() on these throws, which is what the panel used to call.
      expect(meta(isoSpeed: double.infinity).isoDisplay, RawMeta.unknown);
      expect(meta(isoSpeed: double.nan).isoDisplay, RawMeta.unknown);
    });

    test('focal length', () {
      expect(meta(focalLen: 451).focalLenDisplay, '451.0 mm');
      expect(meta(focalLen: 0).focalLenDisplay, RawMeta.unknown);
    });

    test('camera name', () {
      expect(meta().cameraDisplay, 'Nikon Z 6_2');
      expect(meta(make: '', model: '').cameraDisplay, RawMeta.unknown);
    });

    test('resolution', () {
      expect(meta().resolutionDisplay, '6064 × 4040');
      expect(meta(width: 0, height: 0).resolutionDisplay, RawMeta.unknown);
    });
  });
}
