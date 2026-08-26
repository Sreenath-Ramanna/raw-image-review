// lib/src/viewer_screen.dart
//
// Main application screen: browse button, image canvas, metadata panel.

import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'raw_decoder.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  ui.Image? _image;
  RawMeta? _meta;
  bool _loading = false;
  String? _error;

  // Zoom / pan state
  double _scale = 1.0;
  Offset _offset = Offset.zero;

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
    setState(() {
      _loading = true;
      _error = null;
      _image = null;
      _meta = null;
      _scale = 1.0;
      _offset = Offset.zero;
    });

    try {
      final decoded = await RawDecoder.decode(path);
      setState(() {
        _image = decoded.image;
        _meta = decoded.meta;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
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
              onPressed: () => setState(() => _scale = (_scale * 1.25).clamp(0.1, 20.0)),
            ),
            IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.zoom_out, color: Colors.white70),
              onPressed: () => setState(() => _scale = (_scale / 1.25).clamp(0.1, 20.0)),
            ),
            IconButton(
              tooltip: 'Fit to window',
              icon: const Icon(Icons.fit_screen, color: Colors.white70),
              onPressed: () => setState(() {
                _scale = 1.0;
                _offset = Offset.zero;
              }),
            ),
          ],
          const Spacer(),
          if (_loading)
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white54,
                  ),
                ),
                SizedBox(width: 8),
                Text('Decoding…',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
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
        child: CustomPaint(
          painter: _ImagePainter(
            image: _image!,
            scale: _scale,
            offset: _offset,
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
