// Integration test: needs the built libraw_wrapper.so and the local
// test-images/ files, so it skips itself when either is absent.
//
// The embedded preview is stored unrotated while dcraw_process bakes the
// camera orientation into the full decode. If the two disagree, portrait
// shots flash sideways before snapping upright.

// Timings are the point of this test; printing them is deliberate.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/raw_decoder.dart';

const _soPath = 'build/linux/x64/debug/bundle/lib/libraw_wrapper.so';
const _images = 'test-images';

String _orientation(int w, int h) =>
    w > h ? 'landscape' : (h > w ? 'portrait' : 'square');

void main() {
  final so = File(_soPath);
  final haveNative = so.existsSync();

  setUpAll(() {
    if (haveNative) RawDecoder.libraryPathOverride = so.absolute.path;
  });

  Future<void> checkOrientationMatches(String name) async {
    final path = '$_images/$name';
    if (!File(path).existsSync()) {
      markTestSkipped('missing $path');
      return;
    }

    final previewWatch = Stopwatch()..start();
    final preview = await RawDecoder.decodePreview(path);
    previewWatch.stop();

    expect(preview, isNotNull, reason: '$name has no usable embedded preview');

    final fullWatch = Stopwatch()..start();
    final full = await RawDecoder.decode(path);
    fullWatch.stop();

    final p = preview!.image;
    final f = full.image;

    print('$name: preview ${p.width}x${p.height} '
        '(${previewWatch.elapsedMilliseconds} ms) vs '
        'full ${f.width}x${f.height} (${fullWatch.elapsedMilliseconds} ms)');

    expect(
      _orientation(p.width, p.height),
      _orientation(f.width, f.height),
      reason: 'preview orientation does not match the full decode',
    );

    // Preview must actually be faster, or it is pointless.
    expect(previewWatch.elapsedMilliseconds,
        lessThan(fullWatch.elapsedMilliseconds));

    p.dispose();
    f.dispose();
  }

  group('embedded preview', () {
    test('landscape NEF matches full decode orientation', () async {
      await checkOrientationMatches('DSC_1436.NEF');
    }, skip: !haveNative ? 'built .so not found' : null);

    test('portrait NEF (flip=5) matches full decode orientation', () async {
      await checkOrientationMatches('DSC_1441.NEF');
    }, skip: !haveNative ? 'built .so not found' : null);

    test('landscape CR3 matches full decode orientation', () async {
      await checkOrientationMatches('20250803_A0A8111.CR3');
    }, skip: !haveNative ? 'built .so not found' : null);
  });
}
