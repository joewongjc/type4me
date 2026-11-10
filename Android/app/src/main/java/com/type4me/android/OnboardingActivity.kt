package com.type4me.android

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.inputmethod.InputMethodManager
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.button.MaterialButton
import com.type4me.android.data.AppSettings
import com.type4me.android.ime.VoiceImeService
import com.type4me.android.ui.color
import com.type4me.android.ui.dp

/** First-run setup: enable the keyboard, allow the microphone, then import or start. */
class OnboardingActivity : AppCompatActivity() {

    private lateinit var keyboardStatus: TextView
    private lateinit var micStatus: TextView

    private val requestMicrophone = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(color(R.color.screen_bg))
            setPadding(dp(24), dp(32), dp(24), dp(24))
        }
        root.addView(
            TextView(this).apply {
                text = getString(R.string.onboarding_title)
                textSize = 30f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(color(R.color.ink))
            },
        )
        root.addView(
            TextView(this).apply {
                text = getString(R.string.onboarding_subtitle)
                textSize = 16f
                setTextColor(color(R.color.ink_secondary))
                setPadding(0, dp(8), 0, dp(18))
            },
        )

        root.addView(section(getString(R.string.onboarding_keyboard)))
        keyboardStatus = status()
        root.addView(keyboardStatus)
        root.addView(
            button(getString(R.string.open_ime_settings)) {
                startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
            },
        )
        root.addView(
            button(getString(R.string.choose_ime)) {
                getSystemService(InputMethodManager::class.java).showInputMethodPicker()
            },
        )

        root.addView(section(getString(R.string.onboarding_microphone)))
        micStatus = status()
        root.addView(micStatus)
        root.addView(
            button(getString(R.string.grant_mic)) {
                requestMicrophone.launch(Manifest.permission.RECORD_AUDIO)
            },
        )

        root.addView(section(getString(R.string.onboarding_sync)))
        root.addView(
            button(getString(R.string.scan_sync)) {
                startActivity(Intent(this, ScanActivity::class.java))
            },
        )
        root.addView(
            button(getString(R.string.onboarding_done)) {
                AppSettings.setOnboarded(this, true)
                finish()
            },
        )

        val scroll = ScrollView(this).apply { addView(root) }
        setContentView(scroll)
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.updatePadding(top = bars.top, bottom = bars.bottom)
            insets
        }
        ViewCompat.requestApplyInsets(scroll)
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        val imm = getSystemService(InputMethodManager::class.java)
        val ours = ComponentName(this, VoiceImeService::class.java)
        val enabled = imm.enabledInputMethodList.any {
            it.packageName == ours.packageName && it.serviceName == ours.className
        }
        val current = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            imm.currentInputMethodInfo?.let {
                it.packageName == ours.packageName && it.serviceName == ours.className
            } ?: false
        } else {
            // Before Android 14 the secure setting is the only readable
            // source; the input-method list has no "current" entry.
            val setting = runCatching {
                Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            }.getOrNull().orEmpty()
            ComponentName.unflattenFromString(setting) == ours
        }
        keyboardStatus.text = getString(
            when {
                !enabled -> R.string.keyboard_status_off
                current -> R.string.keyboard_status_current
                else -> R.string.keyboard_status_not_current
            },
        )
        val mic = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        micStatus.text = getString(if (mic) R.string.mic_granted else R.string.mic_denied)
    }

    private fun section(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 17f
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setTextColor(color(R.color.ink))
        setPadding(0, dp(18), 0, dp(4))
    }

    private fun status(): TextView = TextView(this).apply {
        textSize = 14f
        setTextColor(color(R.color.ink_secondary))
        setPadding(0, dp(2), 0, dp(6))
    }

    private fun button(label: String, action: () -> Unit): MaterialButton =
        MaterialButton(this).apply {
            text = label
            isAllCaps = false
            setOnClickListener { action() }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(44),
            ).apply { bottomMargin = dp(6) }
        }
}
