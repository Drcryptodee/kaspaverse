import 'package:flutter/material.dart';
import 'package:kaspaverse/src/rust/api/simple.dart';
import 'package:kaspaverse/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(KaspaVerseApp(bridgeProof: greet(name: 'KaspaVerse')));
}

/// P0.1 skeleton: one screen whose only job is to prove the
/// Flutter → FRB → rust/bridge pipeline end to end. P0.3 (hello-DAG)
/// replaces the proof text with live DAA / sink blue score.
class KaspaVerseApp extends StatelessWidget {
  const KaspaVerseApp({super.key, required this.bridgeProof});

  /// Produced by rust/bridge — injected so widget tests run without the
  /// native library.
  final String bridgeProof;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KaspaVerse',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5C7),
          brightness: Brightness.dark,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('KaspaVerse')),
        body: Center(child: Text(bridgeProof)),
      ),
    );
  }
}
