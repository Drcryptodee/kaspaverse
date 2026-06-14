import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Renders a secret buffer's LENGTH as masked dots — never the bytes (INV-3).
/// Rebuilds off the buffer's `ValueNotifier<int>`; shared by the §0.6 secret
/// screens (passphrase unlock, create passphrase / extra word). The UI can see
/// how long the secret is, never what it is.
class MaskedDots extends StatelessWidget {
  const MaskedDots({
    super.key,
    required this.length,
    this.emptyHint = 'Use the keyboard below',
  });

  final ValueListenable<int> length;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: length,
      builder: (context, n, _) {
        if (n == 0) {
          return Text(
            emptyHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: KvColor.textTertiary,
            ),
          );
        }
        return Wrap(
          spacing: KvSpace.s,
          runSpacing: KvSpace.s,
          alignment: WrapAlignment.center,
          children: [
            for (var i = 0; i < n; i++)
              Icon(Icons.circle, size: KvSpace.sm, color: KvColor.primaryMuted),
          ],
        );
      },
    );
  }
}
