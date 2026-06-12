import 'package:flutter/material.dart';
import 'package:kaspaverse/src/rust/frb_generated.dart';
import 'package:kaspaverse/src/services/chain_service.dart';
import 'package:kaspaverse/src/ui/hello_dag_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // Single app-lifetime subscription to the bridge stream (L4); the first
  // call also kicks off the mainnet connection in Rust.
  ChainService.instance.start();
  runApp(KaspaVerseApp(chain: ChainService.instance));
}

/// P0.3 hello-DAG: one screen, live DAA + sink blue score from mainnet.
class KaspaVerseApp extends StatelessWidget {
  const KaspaVerseApp({super.key, required this.chain});

  final ChainService chain;

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
      home: HelloDagScreen(
        connected: chain.connected,
        endpoint: chain.endpoint,
        virtualDaaScore: chain.virtualDaaScore,
        sinkBlueScore: chain.sinkBlueScore,
        error: chain.error,
      ),
    );
  }
}
