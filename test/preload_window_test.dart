// Which files to keep decoded around the current one.
//
// The window drives both preloading and eviction, so an off-by-one here either
// throws away the image the user is looking at, or quietly holds onto ~130 MB
// per extra entry.

import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/viewer_screen.dart';

void main() {
  test('keeps previous, current and next', () {
    expect(preloadWindow(5, 13), [4, 5, 6]);
  });

  test('clamps at the start of the folder', () {
    expect(preloadWindow(0, 13), [0, 1]);
  });

  test('clamps at the end of the folder', () {
    expect(preloadWindow(12, 13), [11, 12]);
  });

  test('a single-file folder keeps just that file', () {
    expect(preloadWindow(0, 1), [0]);
  });

  test('a two-file folder keeps both from either side', () {
    expect(preloadWindow(0, 2), [0, 1]);
    expect(preloadWindow(1, 2), [0, 1]);
  });

  test('always contains the current index', () {
    for (var length = 1; length <= 8; length++) {
      for (var i = 0; i < length; i++) {
        expect(preloadWindow(i, length), contains(i),
            reason: 'index $i of $length dropped the current file');
      }
    }
  });

  test('never returns an out-of-range index', () {
    for (var length = 1; length <= 8; length++) {
      for (var i = 0; i < length; i++) {
        for (final w in preloadWindow(i, length)) {
          expect(w, inInclusiveRange(0, length - 1),
              reason: 'index $i of $length produced $w');
        }
      }
    }
  });

  test('radius controls the size of the window', () {
    expect(preloadWindow(5, 20, radius: 0), [5]);
    expect(preloadWindow(5, 20, radius: 2), [3, 4, 5, 6, 7]);
    // radius r caps the window at 2r+1 entries.
    expect(preloadWindow(10, 100, radius: 3).length, 7);
  });

  test('an empty folder yields nothing', () {
    expect(preloadWindow(0, 0), isEmpty);
  });
}
