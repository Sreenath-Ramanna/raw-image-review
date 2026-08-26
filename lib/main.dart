import 'package:flutter/material.dart';

import 'src/viewer_screen.dart';

void main() {
  runApp(const RawViewerApp());
}

class RawViewerApp extends StatelessWidget {
  const RawViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RAW Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ViewerScreen(),
    );
  }
}
