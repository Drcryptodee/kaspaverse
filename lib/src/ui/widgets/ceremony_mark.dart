import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The quiet emblem of a custody surface (onboarding, locked, enroll): an
/// icon on a dim `primary-muted` disc. Vault-calm by construction (DS-5) — a
/// tinted disc, not a glow effect (§3 rations glow to primary actions and
/// live data). Decorative: excluded from semantics; the heading beside it
/// carries the meaning.
class CeremonyMark extends StatelessWidget {
  const CeremonyMark(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: KvSpace.xxl + KvSpace.l,
        height: KvSpace.xxl + KvSpace.l,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: KvColor.primaryMuted.withValues(alpha: 0.12),
        ),
        child: Icon(icon, size: KvSpace.xl, color: KvColor.primaryMuted),
      ),
    );
  }
}
