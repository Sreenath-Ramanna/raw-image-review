// Times the two halves of a decode separately: the C call into LibRaw, and
// the Dart RGB->RGBA conversion loop.
//
// Run it both ways to see what a release build buys:
//   dart run tool/bench.dart <wrapper.so> <raw>...          # JIT, like debug
//   dart compile exe tool/bench.dart -o /tmp/bench && \
//     /tmp/bench <wrapper.so> <raw>...                      # AOT, like release
//
// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:raw_viewer/src/libraw_bindings.dart';

const int _passes = 3;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: bench <wrapper.so> <raw>...');
    exit(2);
  }

  final bindings = LibRawBindings.open(args[0]);
  // Reported rather than detected: `dart run` disables asserts, so the usual
  // assert-based JIT probe silently reports AOT and mislabels the run.
  print('runtime: ${const bool.fromEnvironment("dart.vm.product") ? "AOT" : "JIT"}'
      '   wrapper: ${args[0].contains("/release/") ? "release -O3" : "debug -O0"}');
  print('passes per file: $_passes  (best of)');

  var totalDecode = 0, totalConvert = 0, files = 0;

  for (final path in args.skip(1)) {
    final name = path.split('/').last;
    var bestDecode = 1 << 30, bestConvert = 1 << 30, w = 0, h = 0;

    for (var pass = 0; pass < _passes; pass++) {
      final pathPtr = path.toNativeUtf8();

      final sw = Stopwatch()..start();
      final resultPtr = bindings.decodeFile(pathPtr);
      sw.stop();
      malloc.free(pathPtr);

      if (resultPtr == nullptr) {
        print('$name: decode failed');
        break;
      }
      final r = resultPtr.ref;
      w = r.width;
      h = r.height;
      final decodeMs = sw.elapsedMilliseconds;

      // Exactly what RawDecoder._decodeInIsolate now does: the wrapper
      // returns RGBA, so this is a bulk copy out of native memory rather than
      // a per-pixel loop.
      final src = r.data.asTypedList(r.dataSize);
      final sw2 = Stopwatch()..start();
      final rgba = Uint8List(r.dataSize)..setAll(0, src);
      sw2.stop();
      if (rgba.length != r.dataSize) throw StateError('short copy');

      bindings.freeResult(resultPtr);

      if (decodeMs < bestDecode) bestDecode = decodeMs;
      if (sw2.elapsedMilliseconds < bestConvert) {
        bestConvert = sw2.elapsedMilliseconds;
      }
    }

    if (bestDecode == 1 << 30) continue;
    files++;
    totalDecode += bestDecode;
    totalConvert += bestConvert;
    final mp = (w * h / 1e6).toStringAsFixed(1);
    print('${name.padRight(24)} ${mp.padLeft(5)} MP   '
        'C decode ${bestDecode.toString().padLeft(5)} ms   '
        'Dart copy ${bestConvert.toString().padLeft(4)} ms   '
        'total ${(bestDecode + bestConvert).toString().padLeft(5)} ms');
  }

  if (files > 0) {
    print('\nmean over $files files: C decode ${totalDecode ~/ files} ms, '
        'Dart copy ${totalConvert ~/ files} ms, '
        'total ${(totalDecode + totalConvert) ~/ files} ms');
  }
}
