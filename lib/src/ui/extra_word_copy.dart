/// **The extra word's name is a function of the phrase's length**, and every
/// string on `O5` that mentions it has to agree.
///
/// The render is titled *13th | 25th word* for exactly this reason: it is the
/// same screen twice. A 12-word phrase takes a **13th** word, a 24-word phrase
/// a **25th**, and the create ceremony draws 12 (`RevealActivity`, D-037) while
/// restore accepts either. The render draws the 24-word case; a build that
/// copied its strings literally would have told every user of the create
/// ceremony to write down a *25th* word for a phrase that has twelve.
///
/// It is not a nicety. The word is the BIP39 PBKDF2 salt, it is typed once,
/// and the paper record is the only place it survives — so the label on the
/// paper and the label on the screen have to be the same label.
library;

/// `13th` for 12 words, `25th` for 24. Ordinals in English are irregular only
/// at 1, 2 and 3 in the units place, and no phrase length in BIP39 puts one
/// there (12 → 13, 15 → 16, 18 → 19, 21 → 22, 24 → 25), so `th` is exact for
/// every length the standard defines rather than a shortcut.
String extraWordOrdinal(int words) => '${words + 1}th';

/// `Add a 13th word?` — `O5`'s heading.
String extraWordHeading(int words) => 'Add a ${extraWordOrdinal(words)} word?';

/// `Use a 13th word` — the toggle that offers it.
String extraWordToggle(int words) => 'Use a ${extraWordOrdinal(words)} word';

/// `Skip — 12 words only` — the plain-text way past it (`O5`, and the founder's
/// standing ruling that this one is never a pill).
String extraWordSkip(int words) => 'Skip — $words words only';

/// `Continue with 13th word` — the primary, naming its object (BG-11).
String extraWordContinue(int words) =>
    'Continue with ${extraWordOrdinal(words)} word';

/// The paragraph under the heading. States the consequence in the first
/// breath, because BG-34 lets EXPLANATION hide behind a mark and never a
/// consequence — and this one is *the money is unreachable*.
String extraWordExplainer(int words) =>
    'Optional. An extra word you choose turns the same $words words into a '
    'completely different wallet. Lose it and the money is unreachable — even '
    'with the $words words.';
