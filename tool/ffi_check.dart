// Dev tool: verifies libraw_bindings.dart against the real libraw_wrapper.so
// without needing the Flutter UI. Exercises the struct marshalling — a field
// offset mismatch between Dart and C shows up here as garbage values.
//
// Usage:
//   dart run tool/ffi_check.dart <path-to-libraw_wrapper.so> <raw-file>...

// This is a command-line diagnostic; stdout is its entire purpose.
// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:raw_viewer/src/libraw_bindings.dart';
import 'package:raw_viewer/src/focus_point.dart';

String _readCharArray(Array<Uint8> arr, int len) {
  final buf = <int>[];
  for (var i = 0; i < len; i++) {
    final c = arr[i];
    if (c == 0) break;
    buf.add(c);
  }
  return String.fromCharCodes(buf).trim();
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/ffi_check.dart <wrapper.so> <raw>...');
    exit(2);
  }

  // Struct sizes must match the C layout exactly.
  print('sizeOf<RawImageResultNative> = ${sizeOf<RawImageResultNative>()} '
      '(C expects 32)');
  print('sizeOf<RawImageMetaNative>   = ${sizeOf<RawImageMetaNative>()} '
      '(C expects 156)');

  final bindings = LibRawBindings.open(args[0]);
  var problems = 0;

  for (final path in args.skip(1)) {
    print('\n=== ${path.split('/').last} ===');
    final pathPtr = path.toNativeUtf8();

    final metaPtr = calloc<RawImageMetaNative>();
    final rc = bindings.readMeta(pathPtr, metaPtr);
    final m = metaPtr.ref;
    print('  meta rc=$rc');
    print('    camera : ${_readCharArray(m.make, 64)} '
        '${_readCharArray(m.model, 64)}');
    print('    size   : ${m.width} x ${m.height}  (flip=${m.flip})');
    print('    iso=${m.isoSpeed} shutter=${m.shutter} '
        'aperture=${m.aperture} focal=${m.focalLen}');
    if (rc != 0) {
      print('    !! metadata read failed');
      problems++;
    }
    // Copy out before freeing — m is a view onto metaPtr, not a snapshot.
    final metaWidth = m.width;
    final metaHeight = m.height;
    calloc.free(metaPtr);

    // ── Focus point ──────────────────────────────────────────────────────
    final focusPtr = calloc<RawFocusPointNative>();
    final frc = bindings.readFocus(pathPtr, focusPtr);
    final fp = focusPtr.ref;
    if (frc != 0) {
      print('  focus  : read failed');
    } else if (fp.valid == 0) {
      print('  focus  : none recorded (vendor=${fp.vendor})');
    } else {
      final vendor = switch (fp.vendor) {
        1 => 'Canon',
        2 => 'Nikon',
        _ => 'vendor ${fp.vendor}',
      };
      print('  focus  : $vendor raw=(${fp.x}, ${fp.y}) '
          'area=${fp.width}x${fp.height} '
          'afImage=${fp.afImageWidth}x${fp.afImageHeight} '
          'flip=${fp.flip} inFocus=${fp.pointsInFocus}');
      final point = FocusPoint(
        vendor: fp.vendor,
        rawX: fp.x,
        rawY: fp.y,
        areaWidth: fp.width,
        areaHeight: fp.height,
        afImageWidth: fp.afImageWidth,
        afImageHeight: fp.afImageHeight,
        flip: fp.flip,
        pointsInFocus: fp.pointsInFocus,
      );
      for (final up in [true, false]) {
        FocusPoint.canonPositiveYIsUp = up;
        final area = point.areaInImage(metaWidth, metaHeight);
        final label = fp.vendor == 1 ? (up ? ' (+Y up)' : ' (+Y down)') : '';
        if (area != null) {
          print('           -> centre (${area.centerX.toStringAsFixed(0)}, '
              '${area.centerY.toStringAsFixed(0)}) of '
              '${metaWidth}x$metaHeight$label');
        }
        if (fp.vendor != 1) break; // only Canon is ambiguous
      }
      FocusPoint.canonPositiveYIsUp = true;
    }
    calloc.free(focusPtr);

    final sw = Stopwatch()..start();
    final resultPtr = bindings.decodeFile(pathPtr);
    sw.stop();
    malloc.free(pathPtr);

    if (resultPtr == nullptr) {
      print('  !! decode returned null');
      problems++;
      continue;
    }

    final r = resultPtr.ref;
    print('  decode ok (${sw.elapsedMilliseconds} ms)');
    print('    ${r.width} x ${r.height} colors=${r.colors} bits=${r.bits} '
        'dataSize=${r.dataSize}');

    if (r.width != metaWidth || r.height != metaHeight) {
      print('    !! metadata size ${metaWidth}x$metaHeight disagrees with '
          'decoded ${r.width}x${r.height}');
      problems++;
    }
    if (r.dataSize != r.width * r.height * r.colors * (r.bits ~/ 8)) {
      print('    !! dataSize inconsistent with dimensions');
      problems++;
    }

    // The wrapper now returns RGBA directly; check that contract holds.
    if (r.colors != 4 || r.bits != 8) {
      print('    !! expected 8-bit RGBA, got colors=${r.colors} bits=${r.bits}');
      problems++;
    }
    final src = r.data.asTypedList(r.dataSize);
    var opaque = true;
    for (var i = 3; i < r.dataSize; i += 4 * 1024) {
      if (src[i] != 255) {
        opaque = false;
        break;
      }
    }
    if (!opaque) {
      print('    !! alpha channel is not fully opaque');
      problems++;
    }
    print('    rgba ok, ${r.dataSize} bytes, '
        'px0=(${src[0]},${src[1]},${src[2]},${src[3]})');

    bindings.freeResult(resultPtr);
  }

  print('\n==== ${problems == 0 ? "ALL OK" : "PROBLEMS"} ($problems) ====');
  exit(problems == 0 ? 0 : 1);
}
