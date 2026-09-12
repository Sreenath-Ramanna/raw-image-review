// lib/src/viewer_screen.dart
//
// Main application screen: browse button, image canvas, metadata panel.

import 'dart:async' show unawaited;
import 'dart:io'
    show
        Directory,
        File,
        FileSystemException,
        Platform,
        Process,
        ProcessException,
        ProcessResult;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'raw_decoder.dart';

/// Extensions treated as camera RAW when scanning a folder. Matched
/// case-insensitively — cameras commonly write .NEF and .CR3 in upper case.
const Set<String> kRawExtensions = {
  'cr2', 'cr3', // Canon
  'nef', // Nikon
  'arw', // Sony
  'raf', // Fujifilm
  'dng', // Adobe
  'orf', // Olympus
  'pef', // Pentax
  'rw2', // Panasonic
  'raw', // generic
};

/// Every RAW file directly inside [dir], sorted by name.
///
/// Not recursive: a shoot folder is the unit people browse, and descending
/// into subfolders would mix unrelated sets together.
List<String> rawFilesIn(Directory dir) {
  final files = <String>[];
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    if (dot < 0) continue;
    if (kRawExtensions.contains(name.substring(dot + 1).toLowerCase())) {
      files.add(entity.path);
    }
  }
  files.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return files;
}

/// Scale that makes [image] fit entirely within [canvas] — both width and
/// height end up no larger than the viewing area. Limited by the tighter of
/// the two axes, so the whole frame is visible rather than cropped.
double fitScaleFor(Size image, Size canvas) => math.min(
      canvas.width / image.width,
      canvas.height / image.height,
    );

/// Moves [path] to the desktop trash.
///
/// Deliberately not `File.delete()`. This is a culling tool pointed at
/// original camera files, and a mis-click on a keeper would otherwise be
/// unrecoverable. `gio` ships with glib2, which GTK already requires.
///
/// Throws with the tool's own message if the file could not be trashed.
Future<void> moveToTrash(String path) async {
  final ProcessResult result;
  try {
    // `--` guards against a filename that begins with a dash.
    result = await Process.run('gio', ['trash', '--', path]);
  } on ProcessException catch (e) {
    throw Exception('could not run `gio trash` (${e.message})');
  }
  if (result.exitCode != 0) {
    final err = (result.stderr as String).trim();
    throw Exception(err.isEmpty ? 'gio trash failed' : err);
  }
}

/// Subfolder that Select moves a keeper into, created beside the originals.
const String kSelectedFolderName = 'selected';

/// A name no file in [dir] is using yet: [name] itself, then `stem (2).ext`,
/// `stem (3).ext` and so on.
///
/// Selecting the same filename twice happens whenever two cards are culled
/// into one folder, and silently overwriting the first frame would lose it.
String freeNameIn(Directory dir, String name) {
  final sep = Platform.pathSeparator;
  if (!File('${dir.path}$sep$name').existsSync()) return name;

  final dot = name.lastIndexOf('.');
  final stem = dot < 0 ? name : name.substring(0, dot);
  final ext = dot < 0 ? '' : name.substring(dot);
  for (var n = 2;; n++) {
    final candidate = '$stem ($n)$ext';
    if (!File('${dir.path}$sep$candidate').existsSync()) return candidate;
  }
}

/// Moves [path] into the `selected` subfolder of the folder it sits in,
/// creating that folder on first use. Returns where the file ended up.
///
/// A move, not a copy: the frame leaves the browsing list, and a second copy
/// on disk would be culled all over again on the next pass.
Future<String> moveToSelected(String path) async {
  final file = File(path);
  final target = Directory(
      '${file.parent.path}${Platform.pathSeparator}$kSelectedFolderName');
  if (!target.existsSync()) target.createSync();

  final name = path.split(Platform.pathSeparator).last;
  final dest =
      '${target.path}${Platform.pathSeparator}${freeNameIn(target, name)}';
  try {
    await file.rename(dest);
  } on FileSystemException {
    // rename() cannot cross a filesystem, which `selected` does when it is a
    // symlink or a mount point rather than a plain subfolder.
    await file.copy(dest);
    await file.delete();
  }
  return dest;
}

/// Indices worth keeping decoded when sitting on [index] — itself plus
/// [radius] either side, clamped to the list.
///
/// Pure, so the window logic is testable without a widget tree.
List<int> preloadWindow(int index, int length, {int radius = 1}) {
  final out = <int>[];
  for (var i = index - radius; i <= index + radius; i++) {
    if (i >= 0 && i < length) out.add(i);
  }
  return out;
}

/// Which entry to show after removing the one at [removedIndex] from a list of
/// [length] items. Null means nothing is left.
///
/// Staying at the same index lands on what *was* the next image, which is what
/// makes rapid culling feel continuous; deleting the last entry steps back
/// instead.
int? indexAfterRemoval({required int length, required int removedIndex}) {
  final remaining = length - 1;
  if (remaining <= 0) return null;
  return removedIndex.clamp(0, remaining - 1);
}

/// A decoded preview held in the cache, with the metadata that came with it.
class _CachedPreview {
  final ui.Image image;
  final RawMeta meta;
  final FocusPoint? focus;
  const _CachedPreview(this.image, this.meta, this.focus);
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  // A full-resolution RAW in a typical window fits at roughly 0.16, so the
  // lower bound has to leave room well below that.
  static const double _minScale = 0.01;
  static const double _maxScale = 20.0;

  ui.Image? _image;
  RawMeta? _meta;
  FocusPoint? _focus;
  bool _showFocusPoint = true;
  String? _fileName;
  bool _loading = false;
  bool _showingPreview = false;
  bool _decodingFull = false;
  String? _error;

  // Guards against a slow decode from an earlier file landing after the user
  // has already opened a different one.
  int _requestId = 0;

  // The RAW files in the opened folder, and where we are in them.
  List<String> _files = const [];
  int _index = 0;

  /// Defaults to on: the confirmation is the one thing standing between a
  /// mis-click and a file leaving the folder.
  bool _confirmDelete = true;
  bool _deleting = false;
  bool _selecting = false;

  /// How many files either side of the current one to keep decoded. 1 gives
  /// the previous/current/next window, so a step in either direction is
  /// instant. Raising it multiplies memory: each preview is very nearly
  /// full resolution, so ~100–130 MB apiece.
  static const int _preloadRadius = 1;

  /// Decoded previews, keyed by file path. The cache owns these images; the
  /// one currently on screen is tracked by [_imageFromCache] so it is never
  /// disposed out from under the painter.
  final Map<String, _CachedPreview> _previewCache = {};
  final Set<String> _previewLoading = {};

  /// True when [_image] belongs to [_previewCache] rather than to this state.
  bool _imageFromCache = false;

  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'viewer-keyboard');

  // Zoom / pan state. _scale maps image pixels to logical screen pixels, so
  // 1.0 is exactly 1:1.
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // Used to measure the canvas when fitting; the size is only known after
  // layout, so read it from the render object rather than tracking it in state.
  final GlobalKey _canvasKey = GlobalKey();

  Size? get _canvasSize {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.size;
  }

  /// Scale at which the whole image fits inside the canvas on both axes.
  double? get _fitScale {
    final image = _image;
    final canvas = _canvasSize;
    if (image == null || canvas == null || canvas.isEmpty) return null;
    return fitScaleFor(
      Size(image.width.toDouble(), image.height.toDouble()),
      canvas,
    );
  }

  void _setScale(double scale) {
    setState(() {
      _scale = scale.clamp(_minScale, _maxScale);
      _offset = Offset.zero;
    });
  }

  void _fitToWindow() {
    final fit = _fitScale;
    if (fit != null) _setScale(fit);
  }

  @override
  void dispose() {
    if (!_imageFromCache) _image?.dispose();
    for (final entry in _previewCache.values) {
      entry.image.dispose();
    }
    _previewCache.clear();
    _keyboardFocus.dispose();
    super.dispose();
  }

  Future<void> _openFolder() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Open Folder of RAW Images',
    );
    // The picker takes keyboard focus; take it back so the arrow keys keep
    // working without the user having to click the window first.
    _keyboardFocus.requestFocus();
    if (picked == null) return;

    final files = rawFilesIn(Directory(picked));
    final folder = picked.split(Platform.pathSeparator).last;

    // None of the previous folder's previews are reachable now.
    _evictPreviewsOutside(const {});

    if (files.isEmpty) {
      setState(() {
        _files = const [];
        _index = 0;
        _replaceImage(null);
        _meta = null;
        _fileName = null;
        _loading = false;
        _error = 'No RAW files in "$folder".';
      });
      return;
    }

    setState(() {
      _files = files;
      _index = 0;
    });
    _decodeFile(files.first);
  }

  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < _files.length - 1;

  void _goTo(int index) {
    if (index < 0 || index >= _files.length || index == _index) return;
    setState(() => _index = index);
    _decodeFile(_files[index]);
  }

  void _previous() => _goTo(_index - 1);
  void _next() => _goTo(_index + 1);

  /// Trashes the current file and drops it from the list, so Previous/Next
  /// never try to load it again.
  Future<void> _deleteCurrent() async {
    if (_files.isEmpty || _deleting || _selecting) return;

    final path = _files[_index];
    final name = path.split(Platform.pathSeparator).last;

    if (_confirmDelete) {
      final confirmed = await _askDeleteConfirmation(name);
      // The dialog takes keyboard focus; reclaim it or the arrow keys go dead.
      _keyboardFocus.requestFocus();
      if (confirmed != true) return;
    }

    setState(() => _deleting = true);

    try {
      await moveToTrash(path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = 'Could not delete "$name": $e';
      });
      return;
    }
    if (!mounted) return;

    setState(() => _deleting = false);
    _dropCurrentFile(path);
  }

  /// Moves the current file into the `selected` subfolder and drops it from
  /// the list, the same way a delete does.
  ///
  /// No confirmation: unlike Delete this is reversible with a drag in the
  /// file manager, and the whole point is to be fast enough to use on every
  /// keeper in a shoot.
  Future<void> _selectCurrent() async {
    if (_files.isEmpty || _deleting || _selecting) return;

    final path = _files[_index];
    final name = path.split(Platform.pathSeparator).last;

    setState(() => _selecting = true);

    try {
      await moveToSelected(path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _selecting = false;
        _error = 'Could not select "$name": $e';
      });
      return;
    }
    if (!mounted) return;

    setState(() => _selecting = false);
    _dropCurrentFile(path);
  }

  /// Drops the current entry, which has just left the folder, and moves on to
  /// whatever takes its place. Shared by Delete and Select — they differ only
  /// in where the file went.
  void _dropCurrentFile(String path) {
    _dropCachedPreview(path);

    final nextIndex =
        indexAfterRemoval(length: _files.length, removedIndex: _index);
    final remaining = List<String>.of(_files)..removeAt(_index);

    if (nextIndex == null) {
      // Nothing left. Bump the request id so any decode still in flight is
      // discarded rather than painting over the empty state.
      _requestId++;
      _evictPreviewsOutside(const {});
      setState(() {
        _files = const [];
        _index = 0;
        _replaceImage(null);
        _meta = null;
        _focus = null;
        _fileName = null;
        _loading = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _files = remaining;
      _index = nextIndex;
    });
    _decodeFile(remaining[nextIndex]);
  }

  Future<bool?> _askDeleteConfirmation(String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to Trash?'),
        content: Text(
          '"$name" will be moved to the Trash.\n\n'
          'You can restore it from your file manager.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
            ),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );
  }

  /// The AF area in decoded-image pixels, if this file recorded one.
  Rect? get _focusArea {
    final image = _image;
    final focus = _focus;
    if (image == null || focus == null) return null;
    final area = focus.areaInImage(image.width, image.height);
    if (area == null) return null;
    return Rect.fromCenter(
      center: Offset(area.centerX, area.centerY),
      width: area.width,
      height: area.height,
    );
  }

  /// Pans so [imagePoint] sits in the middle of the canvas at [scale].
  ///
  /// The painter centres the image and then applies `_offset`, so the offset
  /// needed is the distance from the image centre to the target, scaled.
  void _centreOn(Offset imagePoint, double scale) {
    final image = _image;
    if (image == null) return;
    setState(() {
      _scale = scale.clamp(_minScale, _maxScale);
      _offset = Offset(
        (image.width / 2 - imagePoint.dx) * _scale,
        (image.height / 2 - imagePoint.dy) * _scale,
      );
    });
  }

  /// Opens at 1:1 on the focus point, which is the view a photographer wants
  /// first — critical sharpness where the camera actually focused. Falls back
  /// to fit-to-window when the file records no AF data.
  void _showInitialView() {
    final area = _focusArea;
    if (area == null) {
      _fitToWindow();
      return;
    }
    _centreOn(area.center, 1.0);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // KeyDownEvent only: honouring auto-repeat would queue a multi-second
    // decode per repeat while a key is held.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _next();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _previous();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      // Routed through the same path as the button, so "Confirm delete"
      // governs the key too.
      _deleteCurrent();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyS) {
      _selectCurrent();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _fitToWindow();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _decodeFile(String path) async {
    final request = ++_requestId;
    final cached = _previewCache[path];

    setState(() {
      _loading = true;
      _error = null;
      _showingPreview = cached != null;
      _fileName = path.split(Platform.pathSeparator).last;
      _scale = 1.0;
      _offset = Offset.zero;
      // A preloaded neighbour is on screen with no wait at all; otherwise
      // clear and fall through to decoding it.
      _replaceImage(cached?.image, fromCache: cached != null);
      _meta = cached?.meta;
      _focus = cached?.focus;
    });

    if (cached != null) {
      setState(() => _loading = false);
      _fitAfterLayout();
      // Warm the new neighbours straight away — the user is already looking
      // at this one, so nothing is competing for the wait.
      _preloadAround(_index);
      return;
    }

    // The embedded preview is the whole display path now: the full decode is
    // 2-4 s and is only run when asked for. Preview quality is the camera's
    // own rendering at ~99.7% of full resolution, which is what culling needs.
    try {
      final preview = await RawDecoder.decodePreview(path);
      if (!mounted || request != _requestId) {
        preview?.image.dispose();
        return;
      }
      if (preview != null) {
        setState(() {
          _replaceImage(preview.image);
          _meta = preview.meta;
          _focus = preview.focus;
          _showingPreview = true;
          _loading = false;
        });
        _fitAfterLayout();
        // Only now start on the neighbours: preloading earlier would have
        // competed with the decode the user was actually waiting for.
        _preloadAround(_index);
        return;
      }
    } catch (_) {
      // Fall through — the full decode is the remaining option.
    }

    // No usable embedded preview, so the full decode is the only way to put
    // anything on screen. Not optional in this case.
    await _decodeFull(path, request, refit: true);
  }

  /// Runs the full demosaic and swaps it in for the preview.
  ///
  /// Kept off the normal path: it costs 2-4 s against the preview's ~0.5 s,
  /// and for judging focus and composition the preview is generally enough.
  Future<void> _decodeFull(String path, int request,
      {bool refit = false}) async {
    setState(() {
      _loading = true;
      _decodingFull = true;
      _error = null;
    });

    try {
      final decoded = await RawDecoder.decode(path);
      if (!mounted || request != _requestId) {
        decoded.image.dispose();
        return;
      }
      setState(() {
        _replaceImage(decoded.image);
        _meta = decoded.meta;
        _focus = decoded.focus;
        _showingPreview = false;
        _loading = false;
        _decodingFull = false;
      });
      // Preserve zoom and pan otherwise: the user asked for detail at the
      // place they were already looking.
      if (refit) _fitAfterLayout();
    } catch (e) {
      if (!mounted || request != _requestId) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _decodingFull = false;
      });
    }
  }

  void _requestFullDecode() {
    if (_files.isEmpty || _decodingFull || !_showingPreview) return;
    _decodeFull(_files[_index], _requestId);
  }

  /// Swaps in [next], releasing the GPU memory held by the outgoing image.
  ///
  /// Cached previews are owned by [_previewCache] and outlive the widget's
  /// use of them, so they must not be disposed here — eviction does that.
  void _replaceImage(ui.Image? next, {bool fromCache = false}) {
    if (!_imageFromCache) _image?.dispose();
    _image = next;
    _imageFromCache = fromCache;
  }

  /// Drops cached previews outside [keep], disposing them.
  void _evictPreviewsOutside(Set<String> keep) {
    final stale = _previewCache.keys.where((p) => !keep.contains(p)).toList();
    for (final path in stale) {
      final entry = _previewCache.remove(path)!;
      if (identical(entry.image, _image)) {
        // Still on screen — hand ownership to the widget rather than
        // disposing an image the painter is about to read.
        _imageFromCache = false;
      } else {
        entry.image.dispose();
      }
    }
  }

  void _dropCachedPreview(String path) =>
      _evictPreviewsOutside(_previewCache.keys.where((p) => p != path).toSet());

  /// Decodes previews for the files around [index] so a step either way is
  /// instant, and evicts anything that has fallen outside the window.
  void _preloadAround(int index) {
    if (_files.isEmpty) return;
    final window = preloadWindow(index, _files.length, radius: _preloadRadius);
    final keep = {for (final i in window) _files[i]};
    _evictPreviewsOutside(keep);

    for (final i in window) {
      final path = _files[i];
      if (_previewCache.containsKey(path) || _previewLoading.contains(path)) {
        continue;
      }
      unawaited(_cachePreview(path));
    }
  }

  Future<void> _cachePreview(String path) async {
    _previewLoading.add(path);
    try {
      final preview = await RawDecoder.decodePreview(path);
      if (preview == null) return;

      // The user may have moved on, or deleted the file, while this decoded.
      final stillWanted = mounted &&
          _files.isNotEmpty &&
          preloadWindow(_index, _files.length, radius: _preloadRadius)
              .any((i) => _files[i] == path);

      if (!stillWanted || _previewCache.containsKey(path)) {
        preview.image.dispose();
        return;
      }
      _previewCache[path] =
          _CachedPreview(preview.image, preview.meta, preview.focus);
    } catch (_) {
      // Preloading is best effort; the file is decoded again on arrival.
    } finally {
      _previewLoading.remove(path);
    }
  }

  /// The canvas is not measurable until it has been laid out with the new
  /// image, so the initial view has to wait for the next frame.
  void _fitAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showInitialView();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: Column(
        children: [
          _buildToolbar(),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildImageCanvas()),
                if (_meta != null) _buildMetaPanel(_meta!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      height: 48,
      color: const Color(0xFF2C2C2C),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Text(
            'RAW Viewer',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            onPressed: _openFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Open Folder'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0A84FF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          if (_files.isNotEmpty) ...[
            IconButton(
              tooltip: 'Previous  (←)',
              icon: const Icon(Icons.chevron_left, color: Colors.white70),
              onPressed: _hasPrevious ? _previous : null,
            ),
            IconButton(
              tooltip: 'Next  (→)',
              icon: const Icon(Icons.chevron_right, color: Colors.white70),
              onPressed: _hasNext ? _next : null,
            ),
            Text(
              '${_index + 1} / ${_files.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(width: 8),
          ],
          if (_image != null) ...[
            IconButton(
              tooltip: 'Zoom in',
              icon: const Icon(Icons.zoom_in, color: Colors.white70),
              onPressed: () => setState(
                  () => _scale = (_scale * 1.25).clamp(_minScale, _maxScale)),
            ),
            IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.zoom_out, color: Colors.white70),
              onPressed: () => setState(
                  () => _scale = (_scale / 1.25).clamp(_minScale, _maxScale)),
            ),
            IconButton(
              tooltip: 'Fit to window  (F)',
              icon: const Icon(Icons.fit_screen, color: Colors.white70),
              onPressed: _fitToWindow,
            ),
            IconButton(
              tooltip: _focus == null
                  ? 'No focus point recorded in this file'
                  : (_showFocusPoint ? 'Hide focus point' : 'Show focus point'),
              icon: Icon(
                _showFocusPoint
                    ? Icons.center_focus_strong
                    : Icons.center_focus_weak,
                color: _focus == null
                    ? Colors.white24
                    : (_showFocusPoint
                        ? const Color(0xFF00E676)
                        : Colors.white70),
              ),
              onPressed: _focus == null
                  ? null
                  : () => setState(() => _showFocusPoint = !_showFocusPoint),
            ),
            IconButton(
              tooltip: 'Centre on focus point at 100%',
              icon: const Icon(Icons.my_location, color: Colors.white70),
              onPressed: _focus == null ? null : _showInitialView,
            ),
            TextButton(
              onPressed: () => _setScale(1.0),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                minimumSize: const Size(40, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
              child: const Tooltip(
                message: 'Actual size (100%)',
                child: Text('1:1'),
              ),
            ),
          ],
          const Spacer(),
          if (_loading)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(width: 8),
                Text(_decodingFull ? 'Full decode…' : 'Decoding…',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
              ],
            ),
          if (_showingPreview && !_loading) ...[
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: _requestFullDecode,
              icon: const Icon(Icons.hd_outlined, size: 18),
              label: const Text('Full decode'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          if (_files.isNotEmpty) ...[
            const SizedBox(width: 16),
            ElevatedButton.icon(
              onPressed: _selecting ? null : _selectCurrent,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Select  (S)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF14532D),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF2A3A2A),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
            // Delete controls sit at the far end, well away from
            // Previous/Next and from Select, so a stray click while browsing
            // cannot trash a frame.
            const SizedBox(width: 16),
            _buildConfirmDeleteCheckbox(),
            const SizedBox(width: 4),
            ElevatedButton.icon(
              onPressed: _deleting ? null : _deleteCurrent,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete  (Del)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7F1D1D),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF3A2A2A),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConfirmDeleteCheckbox() {
    return Tooltip(
      message: _confirmDelete
          ? 'Ask before moving a file to the Trash'
          : 'Delete immediately, without asking',
      child: InkWell(
        onTap: () => setState(() => _confirmDelete = !_confirmDelete),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: _confirmDelete,
                  onChanged: (v) =>
                      setState(() => _confirmDelete = v ?? true),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: const BorderSide(color: Colors.white54, width: 1.5),
                  fillColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? const Color(0xFF0A84FF)
                          : Colors.transparent),
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Confirm delete',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageCanvas() {
    if (_error != null) {
      return Center(
        child: Text(
          'Error: $_error',
          style: const TextStyle(color: Colors.redAccent),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_image == null && !_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.camera_roll, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'Open a folder of RAW images to begin',
              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Use ← and → to move between images, Del to discard',
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (_image == null) return const SizedBox.shrink();

    return GestureDetector(
      onPanUpdate: (d) => setState(() => _offset += d.delta),
      child: ClipRect(
        // SizedBox.expand is load-bearing: a childless CustomPaint takes its
        // size from `size` (default Size.zero), and Row's default
        // crossAxisAlignment.center hands down loose vertical constraints, so
        // without this the painter collapses to zero height and draws nothing.
        child: SizedBox.expand(
          key: _canvasKey,
          child: CustomPaint(
            painter: _ImagePainter(
              image: _image!,
              scale: _scale,
              offset: _offset,
              focusArea: _showFocusPoint ? _focusArea : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetaPanel(RawMeta meta) {
    return Container(
      width: 220,
      color: const Color(0xFF242424),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_fileName != null) ...[
            Tooltip(
              message: _fileName!,
              child: Text(
                _fileName!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xDEFFFFFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 12),
          ],
          const Text('EXIF',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const Divider(color: Colors.white12),
          _metaRow('Camera', meta.cameraDisplay),
          _metaRow('Resolution', meta.resolutionDisplay),
          _metaRow('ISO', meta.isoDisplay),
          _metaRow('Shutter', meta.shutterDisplay),
          _metaRow('Aperture', meta.apertureDisplay),
          _metaRow('Focal length', meta.focalLenDisplay),
          const Spacer(),
          if (_image != null)
            Text(
              '${_image!.width} × ${_image!.height} px\n'
              'Scale: ${(_scale * 100).toStringAsFixed(0)}%\n'
              '${_showingPreview ? "Camera preview" : "Full decode"}',
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
        ],
      ),
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontWeight: FontWeight.w600)),
          // Material high-emphasis on dark = white @ 87% alpha. Flutter has no
          // Colors.white87 constant, so spell it out (and keep it const).
          Text(value,
              style: const TextStyle(color: Color(0xDEFFFFFF), fontSize: 12)),
        ],
      ),
    );
  }
}

// ── Canvas painter ────────────────────────────────────────────────────────

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  final double scale;
  final Offset offset;

  /// AF area in image pixels, already resolved; null hides the marker.
  final Rect? focusArea;

  const _ImagePainter({
    required this.image,
    required this.scale,
    required this.offset,
    this.focusArea,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();

    final destW = imgW * scale;
    final destH = imgH * scale;

    final dx = (size.width - destW) / 2 + offset.dx;
    final dy = (size.height - destH) / 2 + offset.dy;

    final src = Rect.fromLTWH(0, 0, imgW, imgH);
    final dst = Rect.fromLTWH(dx, dy, destW, destH);

    canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);

    final focus = focusArea;
    if (focus != null) _paintFocusMarker(canvas, focus, dx, dy);
  }

  /// Draws the AF area over the image. Deliberately prominent — its purpose is
  /// to make a wrong coordinate interpretation obvious at a glance.
  void _paintFocusMarker(Canvas canvas, Rect area, double dx, double dy) {
    final rect = Rect.fromLTWH(
      dx + area.left * scale,
      dy + area.top * scale,
      area.width * scale,
      area.height * scale,
    );

    // Outline in black first so it stays legible over light subjects.
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = const Color(0x99000000),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF00E676),
    );

    // Centre cross, so the exact point is readable when the box is large.
    final c = rect.center;
    const arm = 8.0;
    final cross = Paint()
      ..strokeWidth = 2
      ..color = const Color(0xFF00E676);
    canvas.drawLine(Offset(c.dx - arm, c.dy), Offset(c.dx + arm, c.dy), cross);
    canvas.drawLine(Offset(c.dx, c.dy - arm), Offset(c.dx, c.dy + arm), cross);
  }

  @override
  bool shouldRepaint(_ImagePainter old) =>
      old.image != image ||
      old.scale != scale ||
      old.offset != offset ||
      old.focusArea != focusArea;
}
