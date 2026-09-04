import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/transport.dart';

/// The address book — **names the user gave to addresses**, read by whatever
/// surface needs to say who an address belongs to.
///
/// ## Why this exists as its own service
///
/// The store is old: `contact_names.rs` has kept `address → name` since the
/// messaging lane needed to label a thread, and `transport_set_contact_name`
/// has been the write since. What was missing was a **read that is not a
/// conversation** — names only ever reached Dart joined onto `ConversationDto`,
/// so the Send screen could not ask "who do I know?" without pulling the whole
/// messaging store and depending on a hub it has no business starting.
/// `transport_contact_names` is that read, and this is its one Dart consumer.
///
/// ## The safety rule this service does NOT get to relax
///
/// **A name never replaces an address on a funds surface** (BG-15). A contact
/// name is exactly the shape an address-poisoning attack wants: swap what sits
/// behind "Mara" once, quietly, and every future send goes to the attacker
/// while the user reads a name they trust. So every caller here renders the
/// name *beside* the address it stands for, never instead of it, and the
/// signing ceremony restates all 67 characters whether or not a name matched.
/// The name is a convenience on the way in. The address is what is checked.
///
/// **The name lookup lives on `ContactsScope`, not here.** Every surface reads
/// through the scope it was handed, so a second `nameFor` on the service would
/// be a second place for one answer to be computed — the shape L143 punished.
///
/// ## Staleness, stated
///
/// The cache is refreshed when a surface that renders contacts mounts, and
/// after any write made through [save]. `MessagingService.setContactName`
/// writes the same store from the thread header, so a rename made there does
/// not reach a Send screen that is already open — it reaches the next one.
/// Both go through the one bridge function, so the STORE never forks; only
/// this cache can lag, and only until the next mount.
class ContactsService {
  ContactsService._();

  static final ContactsService instance = ContactsService._();

  /// Bridge seams, one static per call (the service-family pattern), so a
  /// widget test never needs the native library.
  @visibleForTesting
  static Future<List<ContactDto>> Function() readFn = transportContactNames;

  @visibleForTesting
  static Future<void> Function(String address, String name) writeFn =
      (address, name) async {
        await transportSetContactName(address: address, name: name);
      };

  /// Every saved contact, sorted by name in Rust — never re-sorted here, so
  /// two surfaces cannot disagree about the order (BG-21).
  final ValueNotifier<List<ContactDto>> contacts = ValueNotifier(const []);

  /// Null until the first read has landed. A surface that renders a contacts
  /// card must not draw its empty state over an unanswered question — an
  /// address book that flashes "no contacts" before showing three is BG-8's
  /// unknown wearing an answer's face.
  final ValueNotifier<bool> loaded = ValueNotifier(false);

  bool _reading = false;

  /// Re-read the store. Safe to call from `initState`; overlapping calls
  /// collapse to the one in flight.
  Future<void> refresh() async {
    if (_reading) return;
    _reading = true;
    try {
      contacts.value = await readFn();
      loaded.value = true;
    } catch (_) {
      // A failed read is not an empty address book. Keep whatever was last
      // known and leave [loaded] alone: the card then renders what it has,
      // which is the honest answer, rather than claiming the user knows
      // nobody (BG-8).
    } finally {
      _reading = false;
    }
  }

  /// Name (or, with an empty [name], un-name) an address, then re-read.
  ///
  /// The cleaning and the 40-character cap are Rust's (`sanitize_name`), and
  /// the address is validated by the pinned crate's own parse before anything
  /// is stored — so a paste cannot forge a row here and cannot save a name
  /// against something that is not an address (INV-9).
  Future<void> save(String address, String name) async {
    await writeFn(address, name);
    await refresh();
  }

  /// Test hook — drops the cache so one test cannot see another's contacts.
  @visibleForTesting
  void reset() {
    contacts.value = const [];
    loaded.value = false;
    _reading = false;
  }
}
