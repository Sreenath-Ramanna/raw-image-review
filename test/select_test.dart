// Selecting the current image: the `selected` subfolder and the move into it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/viewer_screen.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('raw_viewer_select'));
  tearDown(() => dir.deleteSync(recursive: true));

  File raw(String name, [int byte = 0]) =>
      File('${dir.path}/$name')..writeAsBytesSync([byte]);

  Directory selected() =>
      Directory('${dir.path}/$kSelectedFolderName');

  group('moveToSelected', () {
    test('creates the subfolder on first use and moves the file in', () async {
      final file = raw('DSC_1436.NEF');
      expect(selected().existsSync(), isFalse);

      final dest = await moveToSelected(file.path);

      expect(selected().existsSync(), isTrue);
      expect(file.existsSync(), isFalse, reason: 'a move, not a copy');
      expect(dest, '${selected().path}/DSC_1436.NEF');
      expect(File(dest).existsSync(), isTrue);
    });

    test('reuses the subfolder once it exists', () async {
      await moveToSelected(raw('a.NEF').path);
      await moveToSelected(raw('b.NEF').path);

      expect(
        selected().listSync().map((e) => e.uri.pathSegments.last).toList()..sort(),
        ['a.NEF', 'b.NEF'],
      );
    });

    test('does not overwrite a frame already selected under that name',
        () async {
      await moveToSelected(raw('DSC_1436.NEF', 1).path);
      final second = await moveToSelected(raw('DSC_1436.NEF', 2).path);

      expect(second, '${selected().path}/DSC_1436 (2).NEF');
      expect(File('${selected().path}/DSC_1436.NEF').readAsBytesSync(), [1]);
      expect(File(second).readAsBytesSync(), [2]);
    });

    test('throws when the file is gone', () async {
      await expectLater(
        moveToSelected('${dir.path}/not-here.NEF'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('freeNameIn', () {
    test('keeps the name when nothing occupies it', () {
      expect(freeNameIn(dir, 'DSC_1436.NEF'), 'DSC_1436.NEF');
    });

    test('counts up past every taken name', () {
      raw('DSC_1436.NEF');
      raw('DSC_1436 (2).NEF');
      expect(freeNameIn(dir, 'DSC_1436.NEF'), 'DSC_1436 (3).NEF');
    });

    test('handles a name with no extension', () {
      raw('DSC_1436');
      expect(freeNameIn(dir, 'DSC_1436'), 'DSC_1436 (2)');
    });
  });

  test('a selected folder is not browsed as part of the shoot', () {
    raw('a.NEF');
    selected().createSync();
    File('${selected().path}/b.NEF').writeAsBytesSync([0]);

    // rawFilesIn is not recursive, so selecting a frame takes it out of the
    // list for good — including after the folder is reopened.
    expect(rawFilesIn(dir).map((p) => p.split('/').last), ['a.NEF']);
  });
}
