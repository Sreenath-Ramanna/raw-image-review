// lib/src/raw_decoder.dart
//
// High-level Dart API over the LibRaw FFI bindings.
// Runs decoding on an isolate so the UI never blocks.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import 'libraw_bindings.dart';

// ── Public data classes ───────────────────────────────────────────────────

class RawMeta {
  final String make;
  final String model;
  final double isoSpeed;
  final double shutter;
  final double aperture;
  final double focalLen;
  final int width;
  final int height;

  const RawMeta({
    required this.make,
    required this.model,
    required this.isoSpeed,
    required this.shutter,
    required this.aperture,
    required this.focalLen,
    required this.width,
    required this.height,
  });

  String get shutterDisplay {
    if (shutter >= 1) return '${shutter.toStringAsFixed(0)}s';
    final denom = (1 / shutter).round();
    return '1/${denom}s';
  }

  String get apertureDisplay => 'f/${aperture.toStringAsFixed(1)}';
}

class DecodedRawImage {
  final ui.Image image;
  final RawMeta meta;

  const DecodedRawImage({required this.image, required this.meta});
}

// ── Decoder ───────────────────────────────────────────────────────────────

class RawDecoder {
  // Resolve the .so path relative to the executable at runtime.
  static String get _soPath {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir/lib/libraw_wrapper.so';
  }

  /// Decode [filePath] off the main isolate, returning a [DecodedRawImage].
  static Future<DecodedRawImage> decode(String filePath) async {
    // Run the blocking decode in a separate isolate.
    final pixelData = await Isolate.run(() => _decodeInIsolate(filePath));

    // Build a ui.Image back on the main isolate (required by Flutter).
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixelData.bytes,
      pixelData.width,
      pixelData.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;

    return DecodedRawImage(image: image, meta: pixelData.meta);
  }

  // Runs inside the worker isolate — no Flutter framework calls allowed here.
  static _IsolateResult _decodeInIsolate(String filePath) {
    final bindings = LibRawBindings.open(_soPath);

    final pathPtr = filePath.toNativeUtf8();

    // ── Read metadata (cheap) ────────────────────────────────────────────
    final metaPtr = calloc<RawImageMetaNative>();
    bindings.readMeta(pathPtr, metaPtr);
    final meta = _parseMeta(metaPtr.ref);
    calloc.free(metaPtr);

    // ── Decode pixels ────────────────────────────────────────────────────
    final resultPtr = bindings.decodeFile(pathPtr);
    malloc.free(pathPtr);

    if (resultPtr == nullptr) {
      throw Exception('LibRaw failed to decode: $filePath');
    }

    final result = resultPtr.ref;
    final w = result.width;
    final h = result.height;
    final colors = result.colors; // 3 = RGB
    final srcBytes = result.data.asTypedList(result.dataSize);

    // LibRaw outputs RGB; Flutter needs RGBA.
    final rgba = Uint8List(w * h * 4);
    if (colors == 3) {
      for (int i = 0, j = 0; i < w * h; i++, j += 3) {
        rgba[i * 4]     = srcBytes[j];
        rgba[i * 4 + 1] = srcBytes[j + 1];
        rgba[i * 4 + 2] = srcBytes[j + 2];
        rgba[i * 4 + 3] = 255;
      }
    } else {
      // colors == 4: copy directly
      rgba.setAll(0, srcBytes);
    }

    bindings.freeResult(resultPtr);

    return _IsolateResult(bytes: rgba, width: w, height: h, meta: meta);
  }

  static RawMeta _parseMeta(RawImageMetaNative m) {
    String readStr(Array<Uint8> arr, int len) {
      final buf = <int>[];
      for (int i = 0; i < len; i++) {
        final c = arr[i];
        if (c == 0) break;
        buf.add(c);
      }
      return String.fromCharCodes(buf).trim();
    }

    return RawMeta(
      make: readStr(m.make, 64),
      model: readStr(m.model, 64),
      isoSpeed: m.isoSpeed,
      shutter: m.shutter,
      aperture: m.aperture,
      focalLen: m.focalLen,
      width: m.width,
      height: m.height,
    );
  }
}

// ── Internal isolate transfer object ─────────────────────────────────────

class _IsolateResult {
  final Uint8List bytes;
  final int width;
  final int height;
  final RawMeta meta;
  const _IsolateResult(
      {required this.bytes,
      required this.width,
      required this.height,
      required this.meta});
}
