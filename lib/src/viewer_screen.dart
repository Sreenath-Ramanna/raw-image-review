// lib/src/viewer_screen.dart
//
// Main application screen: browse button, image canvas, metadata panel.

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'raw_decoder.dart';

/// Scale that makes [image] fit entirely within [canvas] — both width and
/// height end up no larger than the viewing area. Limited by the tighter of
/// the two axes, so the whole frame is visible rather than cropped.
double fitScaleFor(Size image, Size canvas) => math.min(
      canvas.width / image.width,
      canvas.height / image.height,
    );

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
  String? _fileName;
  bool _loading = false;
  bool _showingPreview = false;
  String? _error;

  // Guards against a slow decode from an earlier file landing after the user
  // has already opened a different one.
  int _requestId = 0;

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
    super.dispose();
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        // Canon
        'cr2', 'cr3',
        // Nikon
        'nef',
        // Sony
        'arw',
        // Fujifilm
        'raf',
        // Adobe
        'dng',
        // Olympus
        'orf',
        // Pentax
        'pef',
        // Panasonic
        'rw2',
        // Generic
        'raw',
      ],
      dialogTitle: 'Open Camera RAW File',
    );

    if (result == null || result.files.single.path == null) return;
    _decodeFile(result.files.single.path!);
  }

  Future<void> _decodeFile(String path) async {
    final request = ++_requestId;

    setState(() {
      _loading = true;
      _error = null;
      _replaceImage(null);
      _meta = null;
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
      if (!mounted || request != _requestId) {
        preview?.image.dispose();
      } else if (preview != null && _image == null) {
        setState(() {
          _replaceImage(preview.image);
          _meta = preview.meta;
          _showingPreview = true;
        });
        _fitAfterLayout();
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
  /// image, so fitting has to wait for the next frame.
  void _fitAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitToWindow();
    });
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: _loading ? null : _browse,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Open RAW'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0A84FF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
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
        ],
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
              'Open a RAW file to begin',
              style: TextStyle(color: Colors.white38, fontSize: 16),
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
          _metaRow('Camera', '${meta.make} ${meta.model}'),
          _metaRow('Resolution', '${meta.width} × ${meta.height}'),
          _metaRow('ISO', meta.isoSpeed.toInt().toString()),
          _metaRow('Shutter', meta.shutterDisplay),
          _metaRow('Aperture', meta.apertureDisplay),
          _metaRow('Focal length', '${meta.focalLen.toStringAsFixed(1)} mm'),
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

  const _ImagePainter({
    required this.image,
    required this.scale,
    required this.offset,
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
  }

  @override
  bool shouldRepaint(_ImagePainter old) =>
      old.image != image || old.scale != scale || old.offset != offset;
}
