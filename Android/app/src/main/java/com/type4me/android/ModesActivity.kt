package com.type4me.android

import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.pipeline.ModeLibrary
import com.type4me.android.ui.color
import com.type4me.android.ui.dp

/** Settings › Modes: reorder, show/hide and edit every mode, including custom ones. */
class ModesActivity : AppCompatActivity() {

    private lateinit var list: LinearLayout
    private lateinit var header: TextView

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
                setPadding(dp(12), 0, dp(12), 0)
                isClickable = true
                contentDescription = getString(R.string.back)
                setOnClickListener { finish() }
            },
            LinearLayout.LayoutParams(dp(48), dp(56)),
        )
        toolbar.addView(
            TextView(this).apply {
                text = getString(R.string.modes_title)
                textSize = 18f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(color(R.color.ink))
                gravity = android.view.Gravity.CENTER_VERTICAL
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, dp(56), 1f),
        )
        val scroll = android.widget.ScrollView(this)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(4), dp(16), dp(32))
        }
        header = TextView(this).apply {
            textSize = 13f
            setTextColor(color(R.color.ink_secondary))
            setPadding(dp(4), dp(4), dp(4), dp(8))
        }
        content.addView(header)
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(list)
        val add = MaterialButton(this).apply {
            text = getString(R.string.mode_new)
            setOnClickListener {
                startActivity(Intent(this@ModesActivity, ModeEditActivity::class.java))
            }
        }
        content.addView(
            add,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(44),
            ).apply { topMargin = dp(16) },
        )
        scroll.addView(content)
        root.addView(toolbar)
        root.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)

        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            toolbar.applyNavBarTopInset(bars.top)
            view.updatePadding(bottom = bars.bottom)
            insets
        }
        ViewCompat.requestApplyInsets(root)
        render()
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        list.removeAllViews()
        val modes = ModeLibrary.all(this)
        header.text = getString(R.string.modes_desc)
        modes.forEachIndexed { index, mode ->
            val card = MaterialCardView(this).apply {
                radius = dp(16).toFloat()
                cardElevation = 0f
                setCardBackgroundColor(color(R.color.card_bg))
                strokeColor = color(R.color.divider)
                strokeWidth = dp(1)
            }
            val inner = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(12), dp(10), dp(12), dp(10))
            }
            val top = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            val check = CheckBox(this).apply {
                isChecked = mode.onKeyboard
                text = mode.label(this@ModesActivity)
                textSize = 15f
                setTextColor(color(R.color.ink))
                setOnCheckedChangeListener { _, checked ->
                    if (!ModeLibrary.setOnKeyboard(this@ModesActivity, mode.id, checked)) {
                        isChecked = true
                        Toast.makeText(
                            this@ModesActivity,
                            R.string.keyboard_modes_min,
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                }
            }
            top.addView(check, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            top.addView(
                moveButton("↑", R.string.move_up, index > 0) {
                    ModeLibrary.move(this, index, index - 1)
                    render()
                },
            )
            top.addView(
                moveButton("↓", R.string.move_down, index < modes.lastIndex) {
                    ModeLibrary.move(this, index, index + 1)
                    render()
                },
            )
            top.addView(
                TextView(this).apply {
                    text = getString(R.string.mode_edit)
                    textSize = 13f
                    setTextColor(color(R.color.ink))
                    setPadding(dp(10), dp(6), dp(4), dp(6))
                    isClickable = true
                    setOnClickListener {
                        startActivity(
                            Intent(this@ModesActivity, ModeEditActivity::class.java)
                                .putExtra(ModeEditActivity.EXTRA_ID, mode.id),
                        )
                    }
                },
            )
            inner.addView(top)
            inner.addView(
                TextView(this).apply {
                    text = mode.summary(this@ModesActivity)
                    textSize = 12f
                    setTextColor(color(R.color.ink_tertiary))
                    maxLines = 2
                    setPadding(dp(12), dp(2), dp(4), 0)
                },
            )
            card.addView(inner)
            list.addView(
                card,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(8) },
            )
        }
    }

    private fun moveButton(
        label: String,
        description: Int,
        enabled: Boolean,
        action: () -> Unit,
    ): TextView =
        TextView(this).apply {
            text = label
            textSize = 18f
            gravity = Gravity.CENTER
            alpha = if (enabled) 1f else 0.25f
            setTextColor(color(R.color.ink))
            setPadding(dp(8), dp(4), dp(8), dp(4))
            contentDescription = getString(description)
            isClickable = enabled
            if (enabled) setOnClickListener { action() }
        }
}
