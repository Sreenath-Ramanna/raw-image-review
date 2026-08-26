// Folder scanning. The case-insensitivity matters in practice: cameras write
// .NEF and .CR3 in upper case, so a naive lowercase match finds nothing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/viewer_screen.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('raw_files_in_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  void touch(String name) {
    File('${dir.path}${Platform.pathSeparator}$name').writeAsBytesSync(const []);
  }

  List<String> namesFound() => rawFilesIn(dir)
      .map((p) => p.split(Platform.pathSeparator).last)
      .toList();

  test('finds RAW files regardless of extension case', () {
    touch('a.NEF');
    touch('b.nef');
    touch('c.Cr3');
    expect(namesFound(), ['a.NEF', 'b.nef', 'c.Cr3']);
  });

  test('ignores non-RAW files', () {
    touch('photo.NEF');
    touch('photo.jpg');
    touch('notes.txt');
    touch('sidecar.xmp');
    touch('noextension');
    expect(namesFound(), ['photo.NEF']);
  });

  test('sorts by name, case-insensitively', () {
    touch('b.nef');
    touch('A.NEF');
    touch('c.NEF');
    expect(namesFound(), ['A.NEF', 'b.nef', 'c.NEF']);
  });

  test('returns empty for a folder with no RAW files', () {
    touch('readme.md');
    expect(rawFilesIn(dir), isEmpty);
  });

  test('does not descend into subfolders', () {
    touch('top.NEF');
    final sub = Directory('${dir.path}${Platform.pathSeparator}sub')
      ..createSync();
    File('${sub.path}${Platform.pathSeparator}nested.NEF')
        .writeAsBytesSync(const []);
    expect(namesFound(), ['top.NEF']);
  });

  test('covers every advertised extension', () {
    for (final ext in kRawExtensions) {
      touch('shot.$ext');
    }
    expect(rawFilesIn(dir).length, kRawExtensions.length);
  });
}
