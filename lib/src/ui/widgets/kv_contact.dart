import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/transport.dart' show ContactDto;
import '../theme/tokens.dart';
import 'kv_address.dart';
import 'kv_chrome.dart';
import 'kv_glyph.dart';
import 'kv_sheet.dart';

/// **The address book's four faces, built once** (BG-21): the monogram disc,
/// the list row, the "who is this" line that sits beside a funds figure, and
/// the sheet that names an address.
///
/// They live together because they share one law, and a law stated in four
/// files is a law that will be corrected in one (L83):
///
/// > **A name never replaces an address on a funds surface** (BG-15).
///
/// A saved name is precisely the surface an address-poisoning attack wants. It
/// costs an attacker one quiet swap of what sits behind "Mara" to redirect
/// every future send, and the user reads a name they trust the whole way to
/// the signature. So nothing here renders a name alone: every seat pairs it
/// with the address it stands for, and the signing ceremony restates all 67
/// characters whether or not a name matched. The name is a convenience on the
/// way in; the address is the thing that is checked.

/// The monogram disc (`S6a` · `S6` · `S8`, measured: **40 dp**, [KvSpace.rowDisc]).
///
/// A known contact wears the first letter of its name; a stranger wears §4's
/// `identity` glyph, which claims nothing about who the address belongs to.
/// **The two are visibly different on purpose** — a stranger must never
/// inherit the face of somebody you know.
class KvContactAvatar extends StatelessWidget {
  const KvContactAvatar({super.key, this.name, this.size = KvSpace.rowDisc});

  /// Null renders the stranger.
  final String? name;
  final double size;

  /// The letter a name shows. **Grapheme-aware enough for the real cases**:
  /// `characters` would be the complete answer, and the first UTF-16 code unit
  /// is wrong for an emoji or an astral-plane script — so a surrogate pair is
  /// taken whole rather than split into half a character no font can draw.
  static String monogramOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final first = trimmed.codeUnitAt(0);
    final pair = first >= 0xD800 && first <= 0xDBFF && trimmed.length > 1;
    return trimmed.substring(0, pair ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final known = name;
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: KvColor.chip,
      ),
      child: Center(
        child: known == null
            ? KvGlyphIcon(
                KvGlyph.identity,
                size: size * 0.45,
                tone: KvColor.inkMeta,
              )
            : Text(
                monogramOf(known),
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  // `S6a`, measured: cap 10.5 dp ÷ Jakarta's 0.773 = 13.6.
                  fontSize: size * 0.35,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                  fontVariations: KvWeight.w600,
                  color: KvColor.ink,
                ),
              ),
      ),
    );
  }
}

/// One address book row (`S6a`, measured: **64 dp pitch**): the disc, the name
/// over its own address, and a chevron.
///
/// The address under the name is not decoration. It is the row's whole safety
/// property — the user picked this contact by name, and what they are about to
/// route money to is on the same row, in the form they can compare against
/// where they got it.
class KvContactRow extends StatelessWidget {
  const KvContactRow({
    super.key,
    required this.name,
    required this.address,
    required this.onTap,
  });

  final String name;
  final String address;
  final VoidCallback onTap;

  /// `S6a`, measured: three discs at 331.25 · 395.0 · 460.0 dp — which is
  /// [KvSpace.row], the ledger's own pitch. One rhythm, not two.
  static const double height = KvSpace.row;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            KvContactAvatar(name: name),
            const SizedBox(width: KvSpace.s14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 16,
                      height: 20 / 16,
                      fontWeight: FontWeight.w600,
                      fontVariations: KvWeight.w600,
                      color: KvColor.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  KvAddress(address, fontSize: 12),
                ],
              ),
            ),
            const SizedBox(width: KvSpace.s),
            const KvGlyphIcon(KvGlyph.chevron, size: 18, tone: KvColor.inkMeta),
          ],
        ),
      ),
    );
  }
}

/// The name beside a figure on a funds surface (`S7`'s `To  **Mara**`, `S8`'s
/// `To Mara`).
///
/// **Absent, not "Unknown", when no contact matches** (founder, 2026-09-04:
/// *"i change my mind, just put 'save as contact'"*). A row that says `Unknown`
/// states a fact nobody needs and puts a word where the eye expects a name; the
/// seat is either a name or the offer to make one.
class KvContactName extends StatelessWidget {
  const KvContactName({super.key, required this.name, this.size = 13});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
    name,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontFamily: KvFont.ui,
      fontSize: size,
      height: 19 / 13,
      fontWeight: FontWeight.w700,
      fontVariations: KvWeight.w700,
      color: KvColor.ink,
    ),
  );
}

/// A quiet text action — `Save as contact` (`S6b`), and the receipt's version
/// of the same offer.
class KvContactAction extends StatelessWidget {
  const KvContactAction({
    super.key,
    required this.label,
    required this.onTap,
    this.tone = KvColor.inkDim,
  });

  final String label;
  final VoidCallback onTap;
  final Color tone;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Semantics(
      button: true,
      child: Padding(
        // BG-12's 52 dp floor around a 19 dp line: a quiet control is still a
        // control.
        padding: const EdgeInsets.symmetric(
          horizontal: KvSpace.s,
          vertical: KvSpace.m,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 14,
            height: 19 / 14,
            fontWeight: FontWeight.w600,
            fontVariations: KvWeight.w600,
            color: tone,
          ),
        ),
      ),
    ),
  );
}

/// Name an address, or rename one (`S6b`'s *Save as contact*).
///
/// Returns the name that was saved, `''` when the user cleared it, or null
/// when they cancelled — so a caller can tell "cleared" from "left alone",
/// which are different outcomes for a row that was showing a name.
///
/// **The cap and the cleaning are Rust's** (`sanitize_name`: trim, collapse
/// whitespace, drop control characters, bound to 40). The field's own
/// [LengthLimitingTextInputFormatter] is the same bound said early, so the user
/// meets it while typing instead of discovering it after a save — but the
/// enforcement that matters is the one at the write, where no caller can skip
/// it.
Future<String?> showContactNameSheet(
  BuildContext context, {
  required String address,
  String? initial,
}) {
  return Navigator.of(context).push<String>(
    KvSheetRoute<String>(
      builder: (context) =>
          _ContactNameSheet(address: address, initial: initial),
    ),
  );
}

class _ContactNameSheet extends StatefulWidget {
  const _ContactNameSheet({required this.address, this.initial});

  final String address;
  final String? initial;

  @override
  State<_ContactNameSheet> createState() => _ContactNameSheetState();
}

class _ContactNameSheetState extends State<_ContactNameSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial ?? '',
  );
  late final FocusNode _focus = FocusNode();

  /// Rust's `MAX_CONTACT_NAME`, said early so the field stops rather than the
  /// save silently truncating.
  static const int maxName = 40;

  @override
  void initState() {
    super.initState();
    // The sheet exists to take one short string; opening with the caret in it
    // saves a tap on the one control the sheet has.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_name.text.trim());

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: widget.initial == null ? 'Save as contact' : 'Rename contact',
      onCancel: () => Navigator.of(context).pop(),
      onDismiss: () => Navigator.of(context).pop(),
      foot: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.l,
          KvSpace.m,
          KvSpace.l,
          KvSpace.s,
        ),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _name,
          builder: (context, value, _) => KvAction(
            label: value.text.trim().isEmpty && widget.initial != null
                ? 'Remove name'
                : 'Save',
            primary: true,
            inlineReason: true,
            disabledReason: value.text.trim().isEmpty && widget.initial == null
                ? 'Type a name to save'
                : null,
            onTap: _save,
          ),
        ),
      ),
      // **Scrollable, because the sheet opens with the keyboard up.** The
      // panel lifts by the IME inset (`KvSheet`), and what is left of the
      // viewport must still be able to reach the address this sheet binds a
      // name to — that string is the reason the sheet exists (BG-15).
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.l),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: KvSpace.m,
              vertical: KvSpace.s14,
            ),
            decoration: BoxDecoration(
              color: KvColor.chip,
              borderRadius: BorderRadius.circular(KvRadius.control),
            ),
            child: TextField(
              controller: _name,
              focusNode: _focus,
              maxLines: 1,
              autocorrect: false,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              inputFormatters: [LengthLimitingTextInputFormatter(maxName)],
              cursorColor: KvColor.primary,
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: 'Name',
                hintStyle: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 16,
                  height: 20 / 16,
                  color: KvColor.etch,
                ),
              ),
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 16,
                height: 20 / 16,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
                color: KvColor.ink,
              ),
            ),
          ),
          const SizedBox(height: KvSpace.m),
          // **The address, in full, on the surface that binds a name to it.**
          // This is the one moment the user decides that "Mara" means these
          // 67 characters, and it is therefore the one moment the characters
          // have to be readable (BG-15).
          KvAddress(
            widget.address,
            form: KvAddressForm.chunked,
            plated: false,
            selectable: true,
          ),
          const SizedBox(height: KvSpace.m),
          const Text(
            'The name is stored on this phone only. It is never sealed onto '
            'the chain or into a backup.',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkMeta,
            ),
          ),
          const SizedBox(height: KvSpace.m),
        ],
      ),
    );
  }
}

/// The address-book wiring a surface consumes — same law as `FiatScope`.
///
/// Injected rather than reached for, so a widget test drives contacts with
/// three plain values and never needs the native library.
class ContactsScope {
  const ContactsScope({
    required this.contacts,
    required this.refresh,
    required this.save,
  });

  /// Every saved contact, sorted by name in Rust.
  final ValueListenable<List<ContactDto>> contacts;

  /// Re-read the store — called when a surface that renders contacts mounts.
  final Future<void> Function() refresh;

  /// Name, rename, or (with an empty name) un-name an address.
  final Future<void> Function(String address, String name) save;

  /// The name for [address], or null when it is not one we know.
  String? nameFor(String address) {
    for (final c in contacts.value) {
      if (c.address == address) return c.name;
    }
    return null;
  }
}
