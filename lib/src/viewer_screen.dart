// lib/src/viewer_screen.dart
//
// Main application screen: browse button, image canvas, metadata panel.

import 'dart:io'
    show Directory, File, Platform, Process, ProcessException, ProcessResult;
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
    _image?.dispose();
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
    if (_files.isEmpty || _deleting) return;

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

    final nextIndex =
        indexAfterRemoval(length: _files.length, removedIndex: _index);
    final remaining = List<String>.of(_files)..removeAt(_index);

    if (nextIndex == null) {
      // Nothing left. Bump the request id so any decode still in flight is
      // discarded rather than painting over the empty state.
      _requestId++;
      setState(() {
        _files = const [];
        _index = 0;
        _deleting = false;
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
      _deleting = false;
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
    return KeyEventResult.ignored;
  }

  Future<void> _decodeFile(String path) async {
    final request = ++_requestId;

    setState(() {
      _loading = true;
      _error = null;
      _replaceImage(null);
      _meta = null;
      _focus = null;
      _showingPreview = false;
      _fileName = path.split(Platform.pathSeparator).last;
      _scale = 1.0;
      _offset = Offset.zero;
    });

    // Start the full decode first so the preview runs alongside it rather than
    // delaying it.
    final fullDecode = RawDecoder.decode(path);

    // The embedded preview is best-effort: not every file has one, and a
    // failure here must not stop the real decode.
    try {
      final preview = await RawDecoder.decodePreview(path);
      if (preview != null) {
        // Every path that does not adopt the image must dispose it, including
        // the case where the full decode somehow got there first.
        final wanted = mounted && request == _requestId && _image == null;
        if (wanted) {
          setState(() {
            _replaceImage(preview.image);
            _meta = preview.meta;
            _focus = preview.focus;
            _showingPreview = true;
          });
          _fitAfterLayout();
        } else {
          preview.image.dispose();
        }
      }
    } catch (_) {
      // Fall through to the full decode.
    }

    try {
      final decoded = await fullDecode;
      if (!mounted || request != _requestId) {
        decoded.image.dispose();
        return;
      }
      final hadPreview = _image != null;
      setState(() {
        _replaceImage(decoded.image);
        _meta = decoded.meta;
        _focus = decoded.focus;
        _showingPreview = false;
        _loading = false;
      });
      // Only fit if the preview never arrived; refitting here would throw away
      // any zoom or pan the user had already applied to the preview.
      if (!hadPreview) _fitAfterLayout();
    } catch (e) {
      if (!mounted || request != _requestId) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Swaps in [next], releasing the GPU memory held by the outgoing image.
  void _replaceImage(ui.Image? next) {
    _image?.dispose();
    _image = next;
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
              tooltip: 'Fit to window',
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
                Text(
                    _showingPreview
                        ? 'Preview — decoding full image…'
                        : 'Decoding…',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
              ],
            ),
          // Delete controls sit at the far end, well away from Previous/Next,
          // so a stray click while browsing cannot trash a frame.
          if (_files.isNotEmpty) ...[
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
              'Scale: ${(_scale * 100).toStringAsFixed(0)}%',
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
