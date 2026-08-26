// lib/src/raw_decoder.dart
//
// High-level Dart API over the LibRaw FFI bindings.
// Runs decoding on an isolate so the UI never blocks.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
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

  /// Dimensions as displayed: already transposed for portrait frames, so they
  /// match the decoded image rather than the unrotated sensor area.
  final int width;
  final int height;

  /// LibRaw orientation code: 0 none, 3 = 180°, 5 = 90° CCW, 6 = 90° CW.
  final int flip;

  const RawMeta({
    required this.make,
    required this.model,
    required this.isoSpeed,
    required this.shutter,
    required this.aperture,
    required this.focalLen,
    required this.width,
    required this.height,
    required this.flip,
  });

  /// Shown when a value is missing or nonsensical.
  static const String unknown = '—';

  /// True for values LibRaw could not determine. It zero-fills the struct on a
  /// failed read, and these fields are never legitimately zero or negative on a
  /// real exposure.
  static bool _usable(double v) => v.isFinite && v > 0;

  String get shutterDisplay {
    // Guard before dividing: 1/0 is Infinity and Infinity.round() throws
    // UnsupportedError, so an unreadable file would crash the panel rather
    // than just display oddly.
    if (!_usable(shutter)) return unknown;
    if (shutter >= 1) return '${shutter.toStringAsFixed(0)}s';
    final denom = (1 / shutter).round();
    return '1/${denom}s';
  }

  String get apertureDisplay =>
      _usable(aperture) ? 'f/${aperture.toStringAsFixed(1)}' : unknown;

  /// `.round()` throws on Infinity and NaN just as it does above.
  String get isoDisplay =>
      _usable(isoSpeed) ? isoSpeed.round().toString() : unknown;

  String get focalLenDisplay =>
      _usable(focalLen) ? '${focalLen.toStringAsFixed(1)} mm' : unknown;

  String get cameraDisplay {
    final name = '$make $model'.trim();
    return name.isEmpty ? unknown : name;
  }

  String get resolutionDisplay =>
      (width > 0 && height > 0) ? '$width × $height' : unknown;
}

class DecodedRawImage {
  final ui.Image image;
  final RawMeta meta;

  const DecodedRawImage({required this.image, required this.meta});
}

// ── Decoder ───────────────────────────────────────────────────────────────

class RawDecoder {
  /// Overrides the .so location. Only for tests and tooling, which do not run
  /// from the bundle layout that [_soPath] assumes.
  static String? libraryPathOverride;

  // Resolve the .so path relative to the executable at runtime.
  static String get _soPath {
    final override = libraryPathOverride;
    if (override != null) return override;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir/lib/libraw_wrapper.so';
  }

  /// Decodes the camera's embedded preview — a near-full-resolution JPEG on
  /// most bodies — in a fraction of the time a full demosaic takes.
  ///
  /// Returns null when the file carries no usable preview; callers should just
  /// wait for [decode] in that case.
  static Future<DecodedRawImage?> decodePreview(String filePath) async {
    // See decode(): the path must be resolved before crossing into the isolate.
    final soPath = _soPath;
    final thumb = await Isolate.run(() => _thumbInIsolate(filePath, soPath));
    if (thumb == null) return null;

    ui.Image image;
    if (thumb.format == _thumbJpeg) {
      final codec = await ui.instantiateImageCodec(thumb.bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
    } else {
      // Uncompressed RGB — same conversion the full decode path uses.
      final rgba = _rgbToRgba(thumb.bytes, thumb.width, thumb.height, 3);
      image = await _imageFromRgba(rgba, thumb.width, thumb.height);
    }

    // The preview is stored unrotated. Flutter's JPEG decoder may or may not
    // honour an embedded EXIF orientation tag, so rather than assume, check
    // whether the decoded dimensions came back already transposed.
    final alreadyRotated =
        image.width == thumb.height && image.height == thumb.width;
    if (!alreadyRotated) {
      image = await _applyFlip(image, thumb.flip);
    }

    return DecodedRawImage(image: image, meta: thumb.meta);
  }

  /// Rotates [src] according to LibRaw's [flip] code so previews match the
  /// orientation `dcraw_process` bakes into the full decode.
  static Future<ui.Image> _applyFlip(ui.Image src, int flip) async {
    // 0 = upright, 3 = 180°, 5 = 90° CCW, 6 = 90° CW. Anything else is left
    // alone rather than guessed at.
    if (flip != 3 && flip != 5 && flip != 6) return src;

    final w = src.width.toDouble();
    final h = src.height.toDouble();
    final quarterTurn = flip == 5 || flip == 6;
    final destW = quarterTurn ? src.height : src.width;
    final destH = quarterTurn ? src.width : src.height;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    switch (flip) {
      case 3:
        canvas.translate(w, h);
        canvas.rotate(math.pi);
      case 5:
        canvas.translate(0, w);
        canvas.rotate(-math.pi / 2);
      case 6:
        canvas.translate(h, 0);
        canvas.rotate(math.pi / 2);
    }

    canvas.drawImage(src, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    final rotated = await picture.toImage(destW, destH);
    picture.dispose();
    src.dispose();
    return rotated;
  }

  static Future<ui.Image> _imageFromRgba(
      Uint8List bytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static Uint8List _rgbToRgba(
      Uint8List src, int width, int height, int colors) {
    final rgba = Uint8List(width * height * 4);
    if (colors == 3) {
      for (int i = 0, j = 0; i < width * height; i++, j += 3) {
        rgba[i * 4] = src[j];
        rgba[i * 4 + 1] = src[j + 1];
        rgba[i * 4 + 2] = src[j + 2];
        rgba[i * 4 + 3] = 255;
      }
    } else {
      rgba.setAll(0, src);
    }
    return rgba;
  }

  // Runs inside the worker isolate.
  static _ThumbResult? _thumbInIsolate(String filePath, String soPath) {
    final bindings = LibRawBindings.open(soPath);
    final pathPtr = filePath.toNativeUtf8();

    final metaPtr = calloc<RawImageMetaNative>();
    final metaRc = bindings.readMeta(pathPtr, metaPtr);
    final meta = _parseMeta(metaPtr.ref);
    calloc.free(metaPtr);

    final thumbPtr = bindings.decodeThumb(pathPtr);
    malloc.free(pathPtr);

    if (metaRc != 0 || thumbPtr == nullptr) {
      if (thumbPtr != nullptr) bindings.freeThumb(thumbPtr);
      return null;
    }

    final t = thumbPtr.ref;
    // Copy before freeing: the typed list is a view onto native memory.
    final bytes = Uint8List.fromList(t.data.asTypedList(t.dataSize));
    final result = _ThumbResult(
      bytes: bytes,
      format: t.format,
      width: t.width,
      height: t.height,
      flip: t.flip,
      meta: meta,
    );

    bindings.freeThumb(thumbPtr);
    return result;
  }

  /// Decode [filePath] off the main isolate, returning a [DecodedRawImage].
  static Future<DecodedRawImage> decode(String filePath) async {
    // Resolve the library path here: statics are not shared across isolates,
    // so the worker would not see libraryPathOverride. Capturing it in the
    // closure copies it across.
    final soPath = _soPath;
    // Run the blocking decode in a separate isolate.
    final pixelData =
        await Isolate.run(() => _decodeInIsolate(filePath, soPath));

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
  static _IsolateResult _decodeInIsolate(String filePath, String soPath) {
    final bindings = LibRawBindings.open(soPath);

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
      flip: m.flip,
    );
  }
}

// ── Internal isolate transfer objects ────────────────────────────────────

const int _thumbJpeg = 1;

class _ThumbResult {
  final Uint8List bytes;
  final int format;
  final int width;
  final int height;
  final int flip;
  final RawMeta meta;
  const _ThumbResult({
    required this.bytes,
    required this.format,
    required this.width,
    required this.height,
    required this.flip,
    required this.meta,
  });
}


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
