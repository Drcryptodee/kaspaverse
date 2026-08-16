package org.kaspaverse.app

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.random.asKotlinRandom

/**
 * The §0.6 native word-reveal + verify surface (P1.4, D-037/D-039) — the ONE place
 * the 12 create-ceremony words leave Rust. They arrive over the JNI lane
 * ([VaultBridge.nativeRevealCeremonyWords] → `byte[]`), are rendered here, and
 * NEVER become a Dart value (INV-1). A dedicated `FLAG_SECURE` Activity (not a
 * PlatformView, D-039) so the secret window is fully isolated from the Flutter
 * view tree.
 *
 * Lifecycle is the guardian (§0.11): anything that pauses us (Home, back, recents)
 * wipes the `byte[]` and finishes `RESULT_CANCELED`; Dart then `abandonCreate`s the
 * held ceremony. `RESULT_OK` is returned ONLY after the verify quiz passes — there
 * is no skip path.
 *
 * Residual (disclosed, D-033): the transient word `String`s are JVM-GC-managed and
 * cannot be wiped; they are minimized to this Activity's lifetime and de-referenced
 * on teardown. The `byte[]` carrier IS wiped in `finally` the instant it is split.
 */
class RevealActivity : Activity() {
    private val TAG = "RevealActivity" // non-secret lifecycle logs only

    // Design tokens mirrored 1:1 from lib/src/ui/theme/tokens.dart (KvColor). A
    // native surface can't import the Dart tokens; kept in lockstep by hand.
    private val cAbyss = Color.parseColor("#0A0A0B")
    private val cSurfaceAlt = Color.parseColor("#1A1A1E")
    private val cBorder = Color.parseColor("#2A2A2F")
    private val cPrimary = Color.parseColor("#49EACB")
    private val cTextPrimary = Color.parseColor("#F0F0F2")
    private val cTextSecondary = Color.parseColor("#8A8A95")
    // Mirrored from KvColor.warning. tokens.dart reserves error red for fund
    // risk and destruction ONLY (§13), and none of this screen's three red
    // moments qualify: "hold to reveal first" is guidance, "not quite" is a
    // wrong answer, and the bounce notice is a redirection. The native file had
    // no warning token because it was never mirrored (ux-auditor, this wave).
    private val cWarning = Color.parseColor("#FBBF24")

    companion object {
        /**
         * Intent extra carrying candidate decoy words for the verify quiz.
         *
         * Plain BIP39 wordlist entries — the app already ships the list as an
         * asset and Dart reads it. Public data travelling INWARD, which is why
         * it may cross the channel at all: INV-1 governs secrets leaving the
         * native/Rust side, and nothing here is a secret. The user's own words
         * still never leave the JNI lane.
         */
        const val EXTRA_DECOYS = "kv.reveal.decoys"
    }

    /**
     * The shuffles on this screen are SECURITY, not presentation.
     *
     * The board's pre-shuffle order is fully secret-revealing — the phrase in
     * order, then decoys — so the permutation is the only thing standing
     * between a photographed 24-chip board and both membership and ordering.
     * Kotlin's default `shuffled()` is `java.util.Collections.shuffle`'s shared
     * 48-bit LCG, whose state is recoverable from a few outputs; the quiz's
     * asked positions are drawn from the same stream. A predictable permutation
     * would hand back exactly what the dilution was added to take away.
     */
    private val secureShuffle = java.security.SecureRandom().asKotlinRandom()

    private val MATCH = LinearLayout.LayoutParams.MATCH_PARENT
    private val WRAP = LinearLayout.LayoutParams.WRAP_CONTENT

    private var words: Array<String>? = null
    private var revealed = false
    private var done = false

    /**
     * Has the user held to reveal since this reveal screen was built? The quiz is
     * unreachable until they have (F1/D-136) — and a bounced attempt rebuilds the
     * screen, so EVERY quiz attempt is preceded by the words being on the glass.
     */
    private var revealedOnce = false

    private val wordViews = arrayOfNulls<TextView>(12)

    // Verify quiz: confirm the word at each of N distinct positions, in order.
    private val QUIZ_POSITIONS = 4
    private val QUIZ_COLS = 3

    /**
     * Total chips on the quiz board: the user's twelve words PLUS decoys.
     * Never fewer than twelve — see [buildChipSet] for why that floor is the
     * whole security property.
     */
    private val QUIZ_CHIPS = 24
    /** Wrong taps allowed per attempt before we send the user back to the words. */
    private val QUIZ_MAX_WRONG = 3

    private var quizPositions: List<Int> = emptyList()
    private var quizExpected: List<String> = emptyList()
    private var quizProgress = 0
    private var quizWrong = 0
    private var quizChips: MutableList<Button> = ArrayList()
    private var quizPrompt: TextView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // FLAG_SECURE before any content and before a single word is read.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
        window.statusBarColor = cAbyss
        window.navigationBarColor = cAbyss

        if (isAccessibilityActive(this)) {
            // §0.6: a screen reader is on — refuse to render words (no secret logged).
            Log.i(TAG, "accessibility service active — refusing to render recovery words")
            showRefusal()
            return
        }
        val loaded = try {
            loadWords()
        } catch (e: Throwable) {
            // No ceremony in progress / JNI error — fail closed, render nothing.
            Log.i(TAG, "no ceremony to reveal — canceling")
            finishWith(false)
            return
        }
        words = loaded
        Log.i(TAG, "reveal surface shown") // no secret — just that the surface is up
        showReveal()
    }

    override fun onResume() {
        super.onResume()
        // Defensive re-check: a service toggled on between create and resume.
        if (!done && isAccessibilityActive(this)) showRefusal()
    }

    override fun onPause() {
        super.onPause()
        // Leaving the secret screen drops everything (§0.11). If the quiz already
        // passed, `done` is set and this is a no-op.
        if (!done) finishWith(false)
    }

    override fun onDestroy() {
        clearSecrets()
        super.onDestroy()
    }

    // ── word lane ─────────────────────────────────────────────────────────

    private fun loadWords(): Array<String> {
        val bytes = VaultBridge.nativeRevealCeremonyWords()
        try {
            val w = String(bytes, Charsets.UTF_8)
                .split(' ')
                .filter { it.isNotEmpty() }
                .toTypedArray()
            require(w.size == 12) { "expected 12 words, got ${w.size}" }
            return w
        } finally {
            bytes.fill(0) // L9 — wipe the JNI carrier the instant it is split
        }
    }

    private fun clearSecrets() {
        words?.let { for (i in it.indices) it[i] = "" } // drop our refs (D-033)
        words = null
        quizExpected = emptyList()
        quizPositions = emptyList()
        // The VIEWS hold word strings too, and since the chip set became all 12
        // (F1/D-136) that is the whole phrase rather than a third of it. D-039's
        // disclosed residual says refs are dropped on every exit; clearing only
        // the arrays would have made that sentence untrue for 12 of 12 words.
        releaseQuizChips()
        for (v in wordViews) v?.text = ""
    }

    /**
     * Drop the word strings the quiz chips hold, then the chips.
     *
     * Called on teardown AND on the retry path — the 3-wrong-taps bounce detaches
     * a whole chip set, and re-assigning the list without clearing it would leave
     * 12 Buttons each holding one recovery word alive until GC. Teardown airtight
     * and retry leaky is the same residual wearing a new route (ffi-leak-auditor).
     */
    private fun releaseQuizChips() {
        for (c in quizChips) c.text = ""
        quizChips = ArrayList()
    }

    private fun finishWith(ok: Boolean) {
        if (done) return
        done = true
        Log.i(TAG, if (ok) "backup verified" else "reveal canceled")
        setResult(if (ok) RESULT_OK else RESULT_CANCELED)
        clearSecrets()
        finish()
    }

    // ── reveal screen ─────────────────────────────────────────────────────

    private fun showReveal(notice: String? = null) {
        revealed = false
        revealedOnce = false
        quizPrompt = null
        releaseQuizChips() // the bounce detaches a live chip set — drop it now
        // …and the previous grid's TextViews, which hold the SAME String objects
        // as `words`. Usually they show bullets, but Android splits multi-touch
        // across sibling children by default, so a hold on one finger plus a tap
        // on Continue reaches the quiz with real words on the grid. Orphaned
        // uncleared, they outlive clearSecrets() and make D-039's "refs dropped
        // on every exit" false again (wallet-security-auditor, re-verify).
        for (v in wordViews) v?.text = ""

        val root = column().apply {
            setBackgroundColor(cAbyss)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        root.addView(heading("Your recovery words"))
        root.addView(
            body(
                "Write these 12 words on paper, in order, and keep them somewhere " +
                    "only you can reach. Anyone who has them controls your funds."
            )
        )
        root.addView(spacer(dp(12)))
        root.addView(
            strong(
                "This is the only time they are ever shown. The app can never show " +
                    "them to you again — not with your passphrase, not with your " +
                    "fingerprint. Screenshots are blocked, so paper is your only copy."
            )
        )
        if (notice != null) {
            root.addView(spacer(dp(12)))
            root.addView(warning(notice))
        }
        root.addView(spacer(dp(16)))
        root.addView(buildGrid())
        root.addView(spacer(dp(16)))

        // Muted until the words have actually been on the glass; the tap is never
        // dead — it says what is missing (L87's class: no silent disabled control).
        val cont = styledButton("I've written them down", cSurfaceAlt, cTextSecondary, stroke = cBorder)
        val hint = body("")

        val hold = styledButton("Hold to reveal", cSurfaceAlt, cTextPrimary, stroke = cBorder)
        hold.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    revealed = true
                    if (!revealedOnce) {
                        revealedOnce = true
                        armContinue(cont, hint)
                    }
                    refreshGrid()
                    v.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    hold.text = "Release to hide"
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    revealed = false
                    refreshGrid()
                    hold.text = "Hold to reveal"
                    v.performClick()
                }
            }
            true
        }
        root.addView(hold)
        root.addView(spacer(dp(12)))
        root.addView(hint)
        root.addView(spacer(dp(4)))

        cont.setOnClickListener {
            if (revealedOnce) {
                showQuiz()
            } else {
                cont.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                hint.text =
                    "Hold to reveal your words and copy them down first — the next " +
                    "step asks you to put four of them back in place."
                hint.setTextColor(cWarning)
            }
        }
        root.addView(cont)

        setContentView(scroll(root))
        refreshGrid()
    }

    /** The words have been shown at least once: promote Continue to the real CTA. */
    private fun armContinue(cont: Button, hint: TextView) {
        cont.setTextColor(cAbyss)
        cont.background = GradientDrawable().apply {
            cornerRadius = dp(12).toFloat()
            setColor(cPrimary)
        }
        hint.text = ""
    }

    private fun buildGrid(): View {
        val cols = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val left = column().apply { layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f) }
        val right = column().apply { layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f) }
        for (i in 0 until 6) left.addView(wordCell(i))
        for (i in 6 until 12) right.addView(wordCell(i))
        cols.addView(left)
        cols.addView(right)
        return cols
    }

    private fun wordCell(i: Int): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(8), dp(4), dp(8))
        }
        val num = TextView(this).apply {
            text = "${i + 1}"
            setTextColor(cTextSecondary)
            typeface = Typeface.MONOSPACE
            textSize = 13f
            width = dp(28)
        }
        val word = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 16f
        }
        wordViews[i] = word
        row.addView(num)
        row.addView(word)
        return row
    }

    private fun refreshGrid() {
        val w = words ?: return
        for (i in 0 until 12) {
            wordViews[i]?.text = if (revealed) w[i] else "••••••"
            wordViews[i]?.setTextColor(if (revealed) cTextPrimary else cTextSecondary)
        }
    }

    // ── verify quiz ─────────────────────────────────────────────────────────

    private fun showQuiz() {
        val w = words ?: return
        revealed = false
        Log.i(TAG, "verify quiz started")
        // Pick up to 4 positions whose words are DISTINCT (BIP39 can repeat a
        // word) so a tapped word maps to exactly one position.
        val seen = HashSet<String>()
        val chosen = ArrayList<Int>()
        for (p in (0 until 12).shuffled(secureShuffle)) {
            if (seen.add(w[p])) chosen.add(p)
            if (chosen.size == QUIZ_POSITIONS) break
        }
        chosen.sort()
        quizPositions = chosen
        quizExpected = chosen.map { w[it] }
        quizProgress = 0
        quizWrong = 0

        val root = column().apply {
            setBackgroundColor(cAbyss)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        root.addView(heading("Confirm your backup"))
        root.addView(
            body(
                "Tap the matching word for each position, in order. All 12 of your " +
                    "words are here, mixed in with words that are not yours, so only " +
                    "your own copy tells you which one belongs where. Three wrong " +
                    "taps and you go back to the words."
            )
        )
        root.addView(spacer(dp(16)))
        val prompt = TextView(this).apply {
            setTextColor(cPrimary)
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, 0, 0, dp(12))
        }
        quizPrompt = prompt
        root.addView(prompt) // fixed header — never scrolls away from its chips

        // The board is ALL TWELVE of the user's words, plus decoys on top —
        // never a subset of them. D-136 item 1 and `design_system.md:427` both
        // say so ("the candidate set is every word in the phrase, never the
        // answer subset"), and the reason is quantitative, not stylistic.
        //
        // The pinned adversary holds the word multiset but not the order —
        // which is not exotic here, because item 2 FORCES a hold-reveal of all
        // twelve immediately before every attempt, including after a bounce.
        // Against that adversary a board of the 4 answers + 8 decoys is not
        // harder than all-12, it is dramatically easier: the decoys are
        // filtered to be words they do NOT hold, so the board labels its own
        // answers by exclusion. The candidate set collapses 12 -> 4, and four
        // known words over four known positions against a 3-strike budget is a
        // blind pass rate of 3/8 versus all-12's 1/792. Tried, measured and
        // reverted here (wallet-security-auditor BLOCK, 2026-08-16).
        //
        // Decoys ON TOP cost that property nothing: a solver holding the
        // multiset still excludes them and still faces 12 candidates per
        // position, so 1/792 stands exactly — while an OBSERVER of the screen
        // now sees the phrase diluted among 24 words instead of reading it off
        // directly. That is the exposure the founder asked to close, bought
        // with no give-back.
        releaseQuizChips()
        root.addView(
            scroll(chipGrid(buildChipSet(w))).apply {
                layoutParams = LinearLayout.LayoutParams(MATCH, 0, 1f)
            }
        )
        updateQuizPrompt()
        setContentView(root)
    }

    /**
     * The quiz board: **all twelve of the user's words**, diluted with decoys.
     *
     * The twelve are the candidate set D-136 and `design_system.md:427` require
     * — never a subset of them, and never the answers alone. Decoys are added
     * on top purely so an observer cannot read the phrase off the screen; they
     * are plain BIP39 wordlist entries arriving from Dart (public data, inward
     * only). Any colliding with a word the user holds is dropped, so a chip can
     * never be both a decoy and some position's correct answer.
     *
     * With no usable decoys the board is exactly the phrase — D-136's all-12
     * behaviour, the strongest case, not a degraded one. The failure mode to
     * fear here is the opposite direction: **fewer than twelve is never valid**,
     * because a solver holding the multiset excludes every decoy and is then
     * choosing among whatever of their own words remain.
     */
    private fun buildChipSet(words: Array<String>): List<String> {
        val mine = words.toHashSet()
        // Seeded with EVERY word in the phrase. This line is the security
        // property; decoys below are cosmetic dilution on top of it, and must
        // never become a substitute for it.
        val board = LinkedHashSet(words.toList())
        val decoys = (intent.getStringArrayListExtra(EXTRA_DECOYS) ?: arrayListOf())
            .filter { it.isNotBlank() && it !in mine }
            .distinct()
            .shuffled(secureShuffle)
        for (d in decoys) {
            if (board.size >= QUIZ_CHIPS) break
            board.add(d)
        }
        if (board.size < QUIZ_CHIPS) {
            // No count interpolated: it would be `sent - collisions with the
            // phrase`, a value derived from secret material, in logcat.
            Log.i(TAG, "quiz board under-diluted — fewer decoys than asked for")
        }
        return board.toList().shuffled(secureShuffle)
    }

    /** Chips laid out [QUIZ_COLS] to a row so the prompt above stays visible. */
    private fun chipGrid(labels: List<String>): View {
        val grid = column()
        for (rowWords in labels.chunked(QUIZ_COLS)) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8) }
            }
            rowWords.forEachIndexed { c, word ->
                val chip = styledButton(word, cSurfaceAlt, cTextPrimary, stroke = cBorder).apply {
                    textSize = 14f
                    setPadding(dp(4), dp(12), dp(4), dp(12))
                    layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f).apply {
                        if (c > 0) marginStart = dp(8)
                    }
                }
                chip.setOnClickListener { onChipTap(chip, word) }
                quizChips.add(chip)
                row.addView(chip)
            }
            grid.addView(row)
        }
        return grid
    }

    private fun updateQuizPrompt() {
        val pos = quizPositions[quizProgress] + 1
        quizPrompt?.text = "Tap your word #$pos   (${quizProgress + 1} of ${quizExpected.size})"
        quizPrompt?.setTextColor(cPrimary)
    }

    private fun onChipTap(chip: Button, word: String) {
        if (done) return
        if (word == quizExpected[quizProgress]) {
            chip.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            chip.isEnabled = false
            chip.setTextColor(cAbyss)
            chip.background = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                setColor(cPrimary)
            }
            quizProgress++
            if (quizProgress >= quizExpected.size) {
                finishWith(true)
            } else {
                updateQuizPrompt()
            }
        } else {
            chip.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            quizWrong++
            if (quizWrong >= QUIZ_MAX_WRONG) {
                // The cost for guessing, which never punishes a slip: go back to
                // the words. The next attempt re-draws BOTH the positions and the
                // chip order, so nothing this attempt eliminated carries forward —
                // and `revealedOnce` resets, so the words are shown again first.
                Log.i(TAG, "verify quiz returned to reveal after $quizWrong wrong taps")
                showReveal(
                    "That's three wrong taps, so we've brought you back to your " +
                        "words. Check them against your paper — the next round asks " +
                        "about different positions."
                )
                return
            }
            // Reset the sequence; a slip costs only the re-tap (DS-3).
            quizProgress = 0
            for (c in quizChips) {
                c.isEnabled = true
                c.setTextColor(cTextPrimary)
                c.background = GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat()
                    setColor(cSurfaceAlt)
                    setStroke(dp(1), cBorder)
                }
            }
            val left = QUIZ_MAX_WRONG - quizWrong
            quizPrompt?.text = "Not quite — check your paper, then start again from " +
                "the top. $left more wrong ${if (left == 1) "tap" else "taps"} and " +
                "you'll go back to your words."
            quizPrompt?.setTextColor(cWarning)
        }
    }

    // ── a11y refusal ──────────────────────────────────────────────────────

    private fun showRefusal() {
        clearSecrets() // if a service toggled on after load, drop the words now
        val root = column().apply {
            setBackgroundColor(cAbyss)
            setPadding(dp(24), dp(24), dp(24), dp(24))
            gravity = Gravity.CENTER
        }
        root.addView(heading("Secure screen paused"))
        root.addView(
            body(
                "A screen reader or other accessibility service is on. Your recovery " +
                    "words can't be shown while one is active — it could read them " +
                    "aloud or capture them. Turn it off in Settings, then come back to " +
                    "finish setting up."
            )
        )
        root.addView(spacer(dp(24)))
        val back = styledButton("Go back", cSurfaceAlt, cTextPrimary, stroke = cBorder)
        back.setOnClickListener { finishWith(false) }
        root.addView(back)
        setContentView(root)
    }

    // ── view helpers (classic Views, no Compose — D-039) ────────────────────

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun column() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
    }

    private fun scroll(child: View) = ScrollView(this).apply {
        setBackgroundColor(cAbyss)
        addView(child)
    }

    private fun spacer(h: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(MATCH, h)
    }

    private fun heading(t: String) = TextView(this).apply {
        text = t
        setTextColor(cTextPrimary)
        textSize = 22f
        typeface = Typeface.DEFAULT_BOLD
        setPadding(0, 0, 0, dp(8))
    }

    private fun body(t: String) = TextView(this).apply {
        text = t
        setTextColor(cTextSecondary)
        textSize = 14f
        setLineSpacing(dp(4).toFloat(), 1f)
    }

    /** Body weight, full contrast — for a fact the user must not skim past. */
    private fun strong(t: String) = body(t).apply {
        setTextColor(cTextPrimary)
        typeface = Typeface.DEFAULT_BOLD
    }

    /** Why you are back on this screen. Not an error — a redirection. */
    private fun warning(t: String) = body(t).apply {
        setTextColor(cWarning)
    }

    private fun styledButton(text: String, fill: Int, textColor: Int, stroke: Int? = null): Button {
        val bg = GradientDrawable().apply {
            cornerRadius = dp(12).toFloat()
            setColor(fill)
            if (stroke != null) setStroke(dp(1), stroke)
        }
        return Button(this).apply {
            this.text = text
            setTextColor(textColor)
            background = bg
            isAllCaps = false
            textSize = 16f
            minHeight = dp(48)
            stateListAnimator = null
            setPadding(dp(16), dp(12), dp(16), dp(12))
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
        }
    }
}
