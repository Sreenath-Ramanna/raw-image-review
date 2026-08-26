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
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:raw_viewer/src/libraw_bindings.dart';

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
      '(C expects 152)');

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
    print('    size   : ${m.width} x ${m.height}');
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
      print('    note: decoded size differs from metadata size '
          '(expected — metadata reports the raw sensor area)');
    }
    if (r.dataSize != r.width * r.height * r.colors * (r.bits ~/ 8)) {
      print('    !! dataSize inconsistent with dimensions');
      problems++;
    }

    // Reproduce the exact RGB->RGBA conversion from raw_decoder.dart.
    final src = r.data.asTypedList(r.dataSize);
    final w = r.width, h = r.height;
    final rgba = Uint8List(w * h * 4);
    if (r.colors == 3) {
      for (int i = 0, j = 0; i < w * h; i++, j += 3) {
        rgba[i * 4] = src[j];
        rgba[i * 4 + 1] = src[j + 1];
        rgba[i * 4 + 2] = src[j + 2];
        rgba[i * 4 + 3] = 255;
      }
    } else {
      rgba.setAll(0, src);
    }
    print('    rgba ok, ${rgba.length} bytes, '
        'px0=(${rgba[0]},${rgba[1]},${rgba[2]},${rgba[3]})');

    bindings.freeResult(resultPtr);
  }

  print('\n==== ${problems == 0 ? "ALL OK" : "PROBLEMS"} ($problems) ====');
  exit(problems == 0 ? 0 : 1);
}
