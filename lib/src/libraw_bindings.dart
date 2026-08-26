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

// ── Binding loader ────────────────────────────────────────────────────────

class LibRawBindings {
  final DynamicLibrary _lib;

  late final RawDecodeFile decodeFile;
  late final RawReadMeta readMeta;
  late final RawFreeResult freeResult;

  LibRawBindings._(this._lib) {
    decodeFile = _lib
        .lookupFunction<_RawDecodeFileNative, RawDecodeFile>('raw_decode_file');
    readMeta =
        _lib.lookupFunction<_RawReadMetaNative, RawReadMeta>('raw_read_meta');
    freeResult = _lib.lookupFunction<_RawFreeResultNative, RawFreeResult>(
        'raw_free_result');
  }

  factory LibRawBindings.open(String soPath) {
    final lib = DynamicLibrary.open(soPath);
    return LibRawBindings._(lib);
  }
}
