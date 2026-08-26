// lib/src/libraw_bindings.dart
//
// dart:ffi bindings to libraw_wrapper.so.
// Matches the structs and function signatures in src/libraw_wrapper.c.

import 'dart:ffi';
import 'package:ffi/ffi.dart';

// ── Native structs ────────────────────────────────────────────────────────

final class RawImageResultNative extends Struct {
  external Pointer<Uint8> data;

  @Int32()
  external int width;

  @Int32()
  external int height;

  @Int32()
  external int colors;

  @Int32()
  external int bits;

  @Int32()
  external int dataSize;
}

/// Embedded preview. `format` is 1 for a JPEG byte stream, 2 for raw RGB.
/// `flip` is LibRaw's orientation code: 0 none, 3 = 180°, 5 = 90° CCW,
/// 6 = 90° CW. The preview is stored unrotated, unlike the full decode.
final class RawThumbResultNative extends Struct {
  external Pointer<Uint8> data;

  @Int32()
  external int dataSize;

  @Int32()
  external int format;

  @Int32()
  external int width;

  @Int32()
  external int height;

  @Int32()
  external int flip;
}

final class RawImageMetaNative extends Struct {
  @Array(64)
  external Array<Uint8> make;

  @Array(64)
  external Array<Uint8> model;

  @Float()
  external double isoSpeed;

  @Float()
  external double shutter;

  @Float()
  external double aperture;

  @Float()
  external double focalLen;

  @Int32()
  external int width;

  @Int32()
  external int height;
}

// ── Native function typedefs ──────────────────────────────────────────────

typedef _RawDecodeFileNative = Pointer<RawImageResultNative> Function(
    Pointer<Utf8> path);
typedef RawDecodeFile = Pointer<RawImageResultNative> Function(
    Pointer<Utf8> path);

typedef _RawReadMetaNative = Int32 Function(
    Pointer<Utf8> path, Pointer<RawImageMetaNative> out);
typedef RawReadMeta = int Function(
    Pointer<Utf8> path, Pointer<RawImageMetaNative> out);

typedef _RawFreeResultNative = Void Function(
    Pointer<RawImageResultNative> result);
typedef RawFreeResult = void Function(Pointer<RawImageResultNative> result);

typedef _RawDecodeThumbNative = Pointer<RawThumbResultNative> Function(
    Pointer<Utf8> path);
typedef RawDecodeThumb = Pointer<RawThumbResultNative> Function(
    Pointer<Utf8> path);

typedef _RawFreeThumbNative = Void Function(
    Pointer<RawThumbResultNative> thumb);
typedef RawFreeThumb = void Function(Pointer<RawThumbResultNative> thumb);

// ── Binding loader ────────────────────────────────────────────────────────

class LibRawBindings {
  final DynamicLibrary _lib;

  late final RawDecodeFile decodeFile;
  late final RawReadMeta readMeta;
  late final RawFreeResult freeResult;
  late final RawDecodeThumb decodeThumb;
  late final RawFreeThumb freeThumb;

  LibRawBindings._(this._lib) {
    decodeFile = _lib
        .lookupFunction<_RawDecodeFileNative, RawDecodeFile>('raw_decode_file');
    readMeta =
        _lib.lookupFunction<_RawReadMetaNative, RawReadMeta>('raw_read_meta');
    freeResult = _lib.lookupFunction<_RawFreeResultNative, RawFreeResult>(
        'raw_free_result');
    decodeThumb = _lib.lookupFunction<_RawDecodeThumbNative, RawDecodeThumb>(
        'raw_decode_thumb');
    freeThumb =
        _lib.lookupFunction<_RawFreeThumbNative, RawFreeThumb>('raw_free_thumb');
  }

  factory LibRawBindings.open(String soPath) {
    final lib = DynamicLibrary.open(soPath);
    return LibRawBindings._(lib);
  }
}
