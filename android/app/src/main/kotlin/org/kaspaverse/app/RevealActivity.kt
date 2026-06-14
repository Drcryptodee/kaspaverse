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
    private val cError = Color.parseColor("#F87171")

    private val MATCH = LinearLayout.LayoutParams.MATCH_PARENT
    private val WRAP = LinearLayout.LayoutParams.WRAP_CONTENT

    private var words: Array<String>? = null
    private var revealed = false
    private var done = false

    private val wordViews = arrayOfNulls<TextView>(12)

    // Verify quiz: confirm the word at each of N distinct positions, in order.
    private var quizPositions: List<Int> = emptyList()
    private var quizExpected: List<String> = emptyList()
    private var quizProgress = 0
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

    private fun showReveal() {
        val root = column().apply {
            setBackgroundColor(cAbyss)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        root.addView(heading("Your recovery words"))
        root.addView(
            body(
                "Write these 12 words on paper, in order, and keep them somewhere " +
                    "only you can reach. Anyone who has them controls your funds. " +
                    "They are never shown to the rest of the app, and this screen " +
                    "blocks screenshots."
            )
        )
        root.addView(spacer(dp(16)))
        root.addView(buildGrid())
        root.addView(spacer(dp(16)))

        val hold = styledButton("Hold to reveal", cSurfaceAlt, cTextPrimary, stroke = cBorder)
        hold.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    revealed = true
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

        val cont = styledButton("I've written them down", cPrimary, cAbyss)
        cont.setOnClickListener { showQuiz() }
        root.addView(cont)

        setContentView(scroll(root))
        refreshGrid()
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
        for (p in (0 until 12).shuffled()) {
            if (seen.add(w[p])) chosen.add(p)
            if (chosen.size == 4) break
        }
        chosen.sort()
        quizPositions = chosen
        quizExpected = chosen.map { w[it] }
        quizProgress = 0

        val root = column().apply {
            setBackgroundColor(cAbyss)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        root.addView(heading("Confirm your backup"))
        root.addView(
            body(
                "Tap the matching word for each position, in order. This proves your " +
                    "backup works — there is no way to skip it."
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
        root.addView(prompt)

        quizChips = ArrayList()
        for (word in quizExpected.shuffled()) {
            val chip = styledButton(word, cSurfaceAlt, cTextPrimary, stroke = cBorder)
            (chip.layoutParams as LinearLayout.LayoutParams).topMargin = dp(8)
            chip.setOnClickListener { onChipTap(chip, word) }
            quizChips.add(chip)
            root.addView(chip)
        }
        updateQuizPrompt()
        setContentView(scroll(root))
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
            // Reset the whole sequence — early/ wrong tap is no penalty (DS-3).
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
            quizPrompt?.text = "Not quite — check your paper, then start again from the top."
            quizPrompt?.setTextColor(cError)
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
