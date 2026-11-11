package com.type4me.android

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.data.Diagnostics
import com.type4me.android.ui.color
import com.type4me.android.ui.dp

/** Settings › Diagnostics: the last dictations, copyable for an issue report. */
class DiagnosticsActivity : AppCompatActivity() {

    private lateinit var text: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(color(R.color.screen_bg))
        }
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, dp(12), 0)
        }
        toolbar.addView(
            TextView(this).apply {
                text = "‹"
                textSize = 30f
                gravity = Gravity.CENTER
                setTextColor(color(R.color.ink))
                isClickable = true
                contentDescription = getString(R.string.back)
                setOnClickListener { finish() }
            },
            LinearLayout.LayoutParams(dp(48), dp(56)),
        )
        toolbar.addView(
            TextView(this).apply {
                text = getString(R.string.diagnostics)
                textSize = 18f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(color(R.color.ink))
                gravity = android.view.Gravity.CENTER_VERTICAL
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, dp(56), 1f),
        )
        root.addView(toolbar)

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(16), 0, dp(16), dp(8))
        }
        actions.addView(
            MaterialButton(this).apply {
                text = getString(R.string.diagnostics_copy)
                setOnClickListener { copy() }
            },
            LinearLayout.LayoutParams(0, dp(44), 1f).apply { marginEnd = dp(6) },
        )
        actions.addView(
            MaterialButton(this).apply {
                text = getString(R.string.diagnostics_share)
                setOnClickListener { share() }
            },
            LinearLayout.LayoutParams(0, dp(44), 1f).apply { marginEnd = dp(6) },
        )
        actions.addView(
            MaterialButton(this).apply {
                text = getString(R.string.diagnostics_clear)
                setTextColor(color(R.color.brand_red))
                setOnClickListener { confirmClear() }
            },
            LinearLayout.LayoutParams(0, dp(44), 1f),
        )
        root.addView(actions)

        val scroll = ScrollView(this)
        text = TextView(this).apply {
            textSize = 12f
            setTextColor(color(R.color.ink_secondary))
            typeface = android.graphics.Typeface.MONOSPACE
            setPadding(dp(16), dp(4), dp(16), dp(24))
            setTextIsSelectable(true)
        }
        scroll.addView(text)
        root.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            toolbar.applyNavBarTopInset(bars.top)
            view.updatePadding(bottom = bars.bottom)
            insets
        }
        ViewCompat.requestApplyInsets(root)
        reload()
    }

    private fun reload() {
        val value = Diagnostics.read(this)
        text.text = value.ifBlank { getString(R.string.diagnostics_empty) }
    }

    private fun copy() {
        val clipboard = getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText(getString(R.string.diagnostics), Diagnostics.read(this)))
        Toast.makeText(this, R.string.history_copied, Toast.LENGTH_SHORT).show()
    }

    private fun share() {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, Diagnostics.read(this@DiagnosticsActivity))
        }
        startActivity(Intent.createChooser(intent, getString(R.string.diagnostics_share)))
    }

    private fun confirmClear() {
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.diagnostics_clear_confirm)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.diagnostics_clear) { _, _ ->
                Diagnostics.clear(this)
                reload()
            }
            .show()
    }
}
