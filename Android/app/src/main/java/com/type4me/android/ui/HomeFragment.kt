package com.type4me.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.os.Bundle
import android.text.format.DateFormat
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.widget.doAfterTextChanged
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.google.android.material.card.MaterialCardView
import com.type4me.android.MainActivity
import com.type4me.android.R
import com.type4me.android.data.ConfigStore
import com.type4me.android.data.HistoryEntry
import com.type4me.android.data.HistoryStore
import com.type4me.android.databinding.FragmentHomeBinding
import com.type4me.android.databinding.ItemHomeHistoryBinding
import com.type4me.android.pipeline.Mode
import com.type4me.android.pipeline.ModeDefinition
import com.type4me.android.pipeline.ModeLibrary
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The Mac Home page: wordmark, the import card until a service is set up,
 * totals, then every dictation grouped by day with search and mode filters.
 */
class HomeFragment : Fragment(R.layout.fragment_home) {

    private var binding: FragmentHomeBinding? = null
    private var entries: List<HistoryEntry> = emptyList()
    private var query = ""
    private var filter: ModeDefinition? = null
    private val expanded = mutableSetOf<Long>()
    private val chips = LinkedHashMap<ModeDefinition?, TextView>()
    private var reloadJob: Job? = null
    /** Mode ids and labels the chips were built from, in library order. */
    private var chipSignature: List<Pair<String, String>> = emptyList()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val b = FragmentHomeBinding.bind(view)
        binding = b
        // Do not let the search field take first focus and pop the keyboard
        // every time the app opens.
        b.root.isFocusableInTouchMode = true
        b.root.requestFocus()
        b.searchInput.clearFocus()
        view.background = DotGridDrawable(requireContext())
        ViewCompat.setOnApplyWindowInsetsListener(view) { target, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            target.updatePadding(top = bars.top)
            insets
        }
        ViewCompat.requestApplyInsets(view)

        b.importScan.setOnClickListener {
            (activity as? MainActivity)?.openScanner()
        }
        b.clearSearch.setOnClickListener { b.searchInput.setText("") }
        b.searchInput.doAfterTextChanged { editable ->
            query = editable?.toString().orEmpty()
            b.clearSearch.isVisible = query.isNotEmpty()
            renderHistory()
        }
        reload()
    }

    override fun onResume() {
        super.onResume()
        reload()
    }

    override fun onDestroyView() {
        binding = null
        chips.clear()
        chipSignature = emptyList()
        super.onDestroyView()
    }

    fun reload() {
        val b = binding ?: return
        val context = requireContext().applicationContext
        reloadJob?.cancel()
        reloadJob = viewLifecycleOwner.lifecycleScope.launch {
            val loaded = withContext(Dispatchers.IO) { HistoryStore.all(context) }
            if (binding == null) return@launch
            entries = loaded
            expanded.retainAll(entries.mapTo(HashSet()) { it.id })
            syncChips()
            updateStats()
            b.importCard.isVisible = !ConfigStore.hasAsrConfig(requireContext())
            b.emptyCard.isVisible = entries.isEmpty()
            b.historyArea.isVisible = entries.isNotEmpty()
            renderHistory()
        }
    }

    private fun updateStats() {
        val b = binding ?: return
        val todayStart = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val totalChars = entries.sumOf { it.finalText.length }
        val todayChars = entries.filter { it.createdAt >= todayStart }.sumOf { it.finalText.length }
        val minutes = (totalChars * (1.0 / 40 - 1.0 / 200)).roundToInt()
        val number = NumberFormat.getIntegerInstance()

        b.statTodayValue.text = getString(R.string.chars_format, number.format(todayChars))
        b.statTotalValue.text = getString(R.string.chars_format, number.format(totalChars))
        b.statCountValue.text = getString(R.string.times_format, number.format(entries.size))
        b.statSavedValue.text = when {
            minutes < 60 -> getString(R.string.minutes_format, minutes)
            minutes % 60 == 0 -> getString(R.string.hours_format, minutes / 60)
            else -> getString(R.string.hours_minutes_format, minutes / 60, minutes % 60)
        }
    }

    /**
     * Rebuilds the filter chips only when the library's ids or labels
     * changed, which happens after editing modes elsewhere in the app.
     */
    private fun syncChips() {
        val context = requireContext()
        val modes = ModeLibrary.all(context)
        val signature = modes.map { it.id to it.label(context) }
        if (signature == chipSignature) return
        chipSignature = signature
        filter = filter?.let { current -> modes.firstOrNull { it.id == current.id } }
        buildChips(modes)
    }

    private fun buildChips(modes: List<ModeDefinition>) {
        val b = binding ?: return
        val container = b.filterChips
        container.removeAllViews()
        chips.clear()
        addChip(container, null, getString(R.string.filter_all))
        modes.forEach { mode ->
            addChip(container, mode, mode.label(requireContext()))
        }
        updateChips()
    }

    private fun addChip(container: LinearLayout, mode: ModeDefinition?, label: String) {
        val context = requireContext()
        val chip = TextView(context).apply {
            text = label
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(context.dp(16f), 0, context.dp(16f), 0)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                context.dp(34),
            ).apply { marginEnd = context.dp(8) }
            isClickable = true
            isFocusable = true
            setOnClickListener {
                if (filter == mode) return@setOnClickListener
                filter = mode
                updateChips()
                renderHistory()
            }
        }
        container.addView(chip)
        chips[mode] = chip
    }

    private fun updateChips() {
        val context = requireContext()
        chips.forEach { (mode, chip) ->
            val selected = if (mode == null) filter == null else filter?.id == mode.id
            chip.setBackgroundResource(
                if (selected) R.drawable.app_chip_selected else R.drawable.app_chip_normal,
            )
            chip.setTextColor(
                context.color(if (selected) R.color.tab_selected_content else R.color.ink),
            )
            chip.typeface = Typeface.create(Typeface.DEFAULT, if (selected) Typeface.BOLD else Typeface.NORMAL)
        }
    }

    private fun renderHistory() {
        val b = binding ?: return
        val needle = query.trim()
        val filtered = entries.filter { entry ->
            (filter == null || entry.mode == filter!!.id) &&
                (needle.isEmpty() ||
                    entry.finalText.contains(needle, ignoreCase = true) ||
                    entry.rawText.contains(needle, ignoreCase = true))
        }
        b.dayList.removeAllViews()
        b.noMatches.isVisible = filtered.isEmpty()
        b.dayList.isVisible = filtered.isNotEmpty()

        var day = ""
        var card: LinearLayout? = null
        filtered.forEach { entry ->
            val key = dayKey(entry.createdAt)
            if (key != day) {
                day = key
                card = addDay(dayTitle(entry.createdAt))
            }
            addRow(card ?: return@forEach, entry)
        }
    }

    private fun addDay(title: String): LinearLayout {
        val context = requireContext()
        val b = binding ?: return LinearLayout(context)
        val heading = TextView(context).apply {
            text = title
            textSize = 13f
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            setTextColor(context.color(R.color.ink_tertiary))
            setPadding(context.dp(4), context.dp(14), 0, context.dp(2))
        }
        b.dayList.addView(heading)

        val card = MaterialCardView(context).apply {
            radius = context.dp(20).toFloat()
            cardElevation = 0f
            setCardBackgroundColor(context.color(R.color.card_bg))
            strokeColor = context.color(R.color.divider)
            strokeWidth = context.dp(1)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = context.dp(8) }
        }
        val inner = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
        }
        card.addView(
            inner,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        b.dayList.addView(card)
        return inner
    }

    private fun addRow(card: LinearLayout, entry: HistoryEntry) {
        val context = requireContext()
        if (card.childCount > 0) {
            card.addView(
                View(context).apply { setBackgroundColor(context.color(R.color.divider)) },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    context.dp(1),
                ).apply { marginStart = context.dp(16) },
            )
        }
        val row = ItemHomeHistoryBinding.inflate(layoutInflater, card, false)
        card.addView(row.root)

        row.text.text = entry.finalText
        val mode = ModeLibrary.byId(context, entry.mode)?.label(context)
            ?: runCatching { Mode.valueOf(entry.mode).label(context) }.getOrDefault(entry.mode)
        val time = DateFormat.getTimeFormat(context).format(Date(entry.createdAt))
        row.meta.text = if (entry.delivered) {
            getString(R.string.history_meta_format, mode, time)
        } else {
            getString(R.string.history_meta_copied, mode, time)
        }
        row.note.text = entry.note.orEmpty()
        row.note.isVisible = !entry.note.isNullOrBlank()
        row.raw.text = entry.rawText

        fun applyExpanded() {
            val open = entry.id in expanded
            row.text.maxLines = if (open) Int.MAX_VALUE else 2
            row.rawLabel.isVisible = open && entry.rawText != entry.finalText
            row.raw.isVisible = open && entry.rawText != entry.finalText
            row.actions.isVisible = open
        }
        applyExpanded()

        row.row.setOnClickListener {
            if (!expanded.add(entry.id)) expanded.remove(entry.id)
            applyExpanded()
        }
        row.copy.setOnClickListener {
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            clipboard.setPrimaryClip(
                ClipData.newPlainText(context.getString(R.string.app_name), entry.finalText),
            )
            Toast.makeText(context, R.string.history_copied, Toast.LENGTH_SHORT).show()
            row.copy.setImageResource(R.drawable.ic_check)
            row.copy.imageTintList = ColorStateList.valueOf(context.color(R.color.success))
            row.copy.postDelayed({
                row.copy.setImageResource(R.drawable.ic_copy)
                row.copy.imageTintList =
                    ColorStateList.valueOf(context.color(R.color.ink_secondary))
            }, 1_500)
        }
        row.delete.setOnClickListener {
            HistoryStore.delete(context, entry.id)
            expanded.remove(entry.id)
            reload()
        }
    }

    private fun dayKey(millis: Long): String =
        SimpleDateFormat("yyyy-DDD", Locale.US).format(Date(millis))

    private fun dayTitle(millis: Long): String {
        val day = Calendar.getInstance().apply { timeInMillis = millis }
        val now = Calendar.getInstance()
        val sameYear = day.get(Calendar.YEAR) == now.get(Calendar.YEAR)
        if (sameYear && day.get(Calendar.DAY_OF_YEAR) == now.get(Calendar.DAY_OF_YEAR)) {
            return getString(R.string.today)
        }
        val yesterday = (now.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, -1) }
        if (sameYear && day.get(Calendar.DAY_OF_YEAR) == yesterday.get(Calendar.DAY_OF_YEAR)) {
            return getString(R.string.yesterday)
        }
        val locale = resources.configuration.locales[0]
        val pattern = if (locale.language == "zh") {
            if (sameYear) "M月d日 EEE" else "yyyy年M月d日 EEE"
        } else {
            if (sameYear) "MMM d, EEE" else "MMM d, yyyy, EEE"
        }
        return SimpleDateFormat(pattern, locale).format(Date(millis))
    }
}
