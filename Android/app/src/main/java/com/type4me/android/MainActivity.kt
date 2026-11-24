package com.type4me.android

import android.Manifest
import android.animation.ValueAnimator
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.os.Bundle
import android.view.animation.PathInterpolator
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatDelegate
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.os.LocaleListCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import com.type4me.android.databinding.ActivityMainBinding
import com.type4me.android.ui.HomeFragment
import com.type4me.android.ui.SettingsFragment

/**
 * The app shell: the Mac window's sidebar, as a bottom tab bar. Home holds
 * the wordmark, totals and dictation records; Settings mirrors the Mac's
 * grouped pages.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private var tab = TAB_HOME
    private var microphoneRequestPending = false
    private var tabIndicatorPlaced = false

    private val requestMicrophone = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {
        microphoneRequestPending = false
        refreshScreens()
    }

    private val backCallback = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() {
            if (tab == TAB_SETTINGS) {
                selectTab(TAB_HOME)
            } else {
                isEnabled = false
                onBackPressedDispatcher.onBackPressed()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applySavedLanguage()
        enableEdgeToEdge()
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.tabBarBlur.sourceView = binding.content

        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime())
            // The keyboard takes the tab bar's place while it is open, so
            // the visible area above it belongs to the content.
            val bottom = maxOf(bars.bottom, keyboard.bottom)
            binding.tabBarHost.isVisible = keyboard.bottom == 0
            view.updatePadding(bottom = bottom)
            insets
        }

        binding.tabHome.setOnClickListener { selectTab(TAB_HOME) }
        binding.tabSettings.setOnClickListener { selectTab(TAB_SETTINGS) }

        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .add(R.id.content, HomeFragment(), TAG_HOME)
                .add(R.id.content, SettingsFragment(), TAG_SETTINGS)
                .commitNow()
            selectTab(TAB_HOME)
        } else {
            tab = savedInstanceState.getInt(KEY_TAB, TAB_HOME)
            showTabFragments()
        }

        onBackPressedDispatcher.addCallback(this, backCallback)
        handleIntent(intent)
        showConsentIfNeeded()
        if (!com.type4me.android.data.AppSettings.onboarded(this) &&
            !com.type4me.android.data.ConfigStore.hasAsrConfig(this)
        ) {
            startActivity(Intent(this, OnboardingActivity::class.java))
        }
    }

    private var consentShown = false

    private fun consentPreferences() =
        getSharedPreferences(PREFS, MODE_PRIVATE)

    private fun showConsentIfNeeded() {
        if (consentShown) return
        if (!com.type4me.android.data.ConfigStore.hasAsrConfig(this)) return
        if (com.type4me.android.data.AppSettings.aiConsent(this)) return
        if (consentPreferences().getBoolean(KEY_CONSENT_DECLINED, false)) return
        consentShown = true
        com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
            .setTitle(R.string.ai_consent_title)
            .setMessage(R.string.ai_consent_body)
            .setNegativeButton(R.string.ai_consent_decline) { _, _ ->
                consentPreferences().edit().putBoolean(KEY_CONSENT_DECLINED, true).apply()
            }
            .setPositiveButton(R.string.ai_consent_agree) { _, _ ->
                com.type4me.android.data.AppSettings.setAiConsent(this, true)
                consentPreferences().edit().remove(KEY_CONSENT_DECLINED).apply()
                refreshScreens()
            }
            .setOnCancelListener {
                consentPreferences().edit().putBoolean(KEY_CONSENT_DECLINED, true).apply()
            }
            .setOnDismissListener { consentShown = false }
            .show()
    }

    private fun applySavedLanguage() {
        val value = com.type4me.android.data.AppSettings.language(this)
        val tags = when (value) {
            "zh" -> "zh-Hans"
            "en" -> "en"
            else -> ""
        }
        if (AppCompatDelegate.getApplicationLocales().toLanguageTags() == tags) return
        AppCompatDelegate.setApplicationLocales(
            if (tags.isEmpty()) LocaleListCompat.getEmptyLocaleList()
            else LocaleListCompat.forLanguageTags(tags),
        )
    }

    override fun onResume() {
        super.onResume()
        refreshScreens()
        showConsentIfNeeded()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt(KEY_TAB, tab)
        super.onSaveInstanceState(outState)
    }

    fun openScanner() {
        startActivity(Intent(this, ScanActivity::class.java))
    }

    fun refreshScreens() {
        (supportFragmentManager.findFragmentByTag(TAG_HOME) as? HomeFragment)?.reload()
        (supportFragmentManager.findFragmentByTag(TAG_SETTINGS) as? SettingsFragment)?.refresh()
    }

    private fun selectTab(target: Int) {
        tab = target
        showTabFragments()
    }

    private fun showTabFragments() {
        val home = supportFragmentManager.findFragmentByTag(TAG_HOME)
        val settings = supportFragmentManager.findFragmentByTag(TAG_SETTINGS)
        supportFragmentManager.beginTransaction().apply {
            when (tab) {
                TAB_HOME -> {
                    home?.let(::show)
                    settings?.let(::hide)
                }

                else -> {
                    home?.let(::hide)
                    settings?.let(::show)
                }
            }
        }.commitNow()
        updateTabs()
    }

    private fun updateTabs() {
        val home = tab == TAB_HOME
        binding.tabHome.isSelected = home
        binding.tabSettings.isSelected = !home
        binding.tabHome.contentDescription = getString(R.string.tab_home)
        binding.tabSettings.contentDescription = getString(R.string.tab_settings)
        val selected = ContextCompat.getColor(this, R.color.tab_selected_icon)
        val plain = ContextCompat.getColor(this, R.color.ink_secondary)
        binding.tabHomeIcon.imageTintList = ColorStateList.valueOf(if (home) selected else plain)
        binding.tabHomeLabel.setTextColor(if (home) selected else plain)
        binding.tabSettingsIcon.imageTintList = ColorStateList.valueOf(if (home) plain else selected)
        binding.tabSettingsLabel.setTextColor(if (home) plain else selected)
        placeTabIndicator(home, animate = tabIndicatorPlaced)
        tabIndicatorPlaced = true
        binding.tabBarBlur.invalidate()
    }

    private fun placeTabIndicator(home: Boolean, animate: Boolean) {
        val place = {
            val target = if (home) {
                0f
            } else {
                (binding.tabSettings.left - binding.tabHome.left).toFloat()
            }
            val indicator = binding.tabIndicator
            indicator.animate().cancel()
            if (animate && ValueAnimator.areAnimatorsEnabled()) {
                indicator.animate()
                    .translationX(target)
                    .setDuration(TAB_INDICATOR_ANIMATION_MS)
                    .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
                    .start()
            } else {
                indicator.translationX = target
            }
        }
        if (binding.tabHome.isLaidOut && binding.tabHome.width > 0) {
            place()
        } else {
            binding.tabHome.post(place)
        }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        handleDeepLink(intent)
        val wantsMicrophone = intent.getBooleanExtra(EXTRA_REQUEST_MICROPHONE, false)
        val openSettings = intent.getBooleanExtra(EXTRA_OPEN_SETTINGS, false)
        intent.removeExtra(EXTRA_OPEN_SETTINGS)
        intent.removeExtra(EXTRA_REQUEST_MICROPHONE)
        if (openSettings || wantsMicrophone) selectTab(TAB_SETTINGS)
        if (!wantsMicrophone || microphoneRequestPending) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            microphoneRequestPending = true
            binding.root.post { requestMicrophone.launch(Manifest.permission.RECORD_AUDIO) }
        }
    }

    /**
     * Consumes a type4me:// URI and clears it from the Intent, so recreating
     * the activity does not open the same import twice.
     */
    private fun handleDeepLink(intent: Intent) {
        val data = intent.data ?: return
        if (data.scheme != "type4me") return
        val text = data.toString()
        intent.data = null
        intent.removeExtra(Intent.EXTRA_TEXT)
        // Do not forward a hostile URI through an Intent extra: Binder
        // transactions are size-limited and this activity is exported.
        if (text.length > MAX_DEEP_LINK_TEXT_CHARS) {
            Toast.makeText(this, R.string.scan_failed, Toast.LENGTH_SHORT).show()
            return
        }
        val payload = runCatching {
            com.type4me.android.data.TransferCodec.decode(text)
        }.getOrNull()
        if (payload != null) {
            com.type4me.android.data.PendingImport.payload = payload
            startActivity(Intent(this, ImportActivity::class.java))
        } else {
            startActivity(
                Intent(this, ScanActivity::class.java)
                    .putExtra(ScanActivity.EXTRA_SEED, text),
            )
        }
    }

    companion object {
        const val EXTRA_REQUEST_MICROPHONE = "request_microphone"
        const val EXTRA_OPEN_SETTINGS = "open_settings"
        private const val TAB_HOME = 0
        private const val TAB_SETTINGS = 1
        private const val KEY_TAB = "tab"
        private const val PREFS = "type4me_prefs"
        private const val KEY_CONSENT_DECLINED = "ai.consent.declined"
        private const val TAG_HOME = "home"
        private const val TAG_SETTINGS = "settings"
        private const val MAX_DEEP_LINK_TEXT_CHARS = 512 * 1024
        private const val TAB_INDICATOR_ANIMATION_MS = 280L
    }
}
