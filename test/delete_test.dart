// Deleting the current image: which entry to show next, and the trash call.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raw_viewer/src/viewer_screen.dart';

void main() {
  group('indexAfterRemoval', () {
    test('stays put, landing on what was the next image', () {
      // [a, b, c, d] showing b (1). After removing b the list is [a, c, d]
      // and index 1 is c — the next frame, so culling flows forward.
      expect(indexAfterRemoval(length: 4, removedIndex: 1), 1);
    });

    test('steps back when the last entry is removed', () {
      // [a, b, c] showing c (2) -> [a, b], must not stay at 2.
      expect(indexAfterRemoval(length: 3, removedIndex: 2), 1);
    });

    test('returns null when the last remaining file goes', () {
      expect(indexAfterRemoval(length: 1, removedIndex: 0), isNull);
    });

    test('removing the first of two lands on the survivor', () {
      expect(indexAfterRemoval(length: 2, removedIndex: 0), 0);
    });

    test('removing the second of two steps back to the first', () {
      expect(indexAfterRemoval(length: 2, removedIndex: 1), 0);
    });

    test('never returns an index outside the shortened list', () {
      for (var length = 1; length <= 6; length++) {
        for (var removed = 0; removed < length; removed++) {
          final next = indexAfterRemoval(length: length, removedIndex: removed);
          if (next == null) {
            expect(length, 1, reason: 'null only when the list empties');
          } else {
            expect(next, inInclusiveRange(0, length - 2),
                reason: 'length=$length removed=$removed went out of range');
          }
        }
      }
    });
  });

  group('moveToTrash', () {
    test('removes the file from its folder', () async {
      // Deliberately not Directory.systemTemp: /tmp is usually tmpfs, and
      // `gio trash` refuses with "Trashing on system internal mounts is not
      // supported". Real photos live on a normal filesystem, so test there.
      final home = Platform.environment['HOME'];
      if (home == null) {
        markTestSkipped('no HOME');
        return;
      }
      final dir = Directory(home).createTempSync('raw_viewer_trash_test');
      // Unique name so the cleanup below cannot match anything else.
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${dir.path}/raw_viewer_test_$stamp.NEF')
        ..writeAsBytesSync(const [0]);

      expect(file.existsSync(), isTrue);
      await moveToTrash(file.path);
      expect(file.existsSync(), isFalse,
          reason: 'file should no longer be in the folder');

      // Leave the user's trash as we found it.
      final name = file.uri.pathSegments.last;
      final trashed = File('$home/.local/share/Trash/files/$name');
      final info = File('$home/.local/share/Trash/info/$name.trashinfo');
      if (trashed.existsSync()) trashed.deleteSync();
      if (info.existsSync()) info.deleteSync();
      dir.deleteSync(recursive: true);
    }, skip: !Platform.isLinux ? 'gio trash is Linux-only' : null);

    test('throws when the file does not exist', () async {
      await expectLater(
        moveToTrash('/nonexistent/raw_viewer/definitely-not-here.NEF'),
        throwsA(isA<Exception>()),
      );
    }, skip: !Platform.isLinux ? 'gio trash is Linux-only' : null);
  });
}
