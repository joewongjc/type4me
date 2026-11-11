package com.type4me.android

import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.LinearLayout
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.data.Snippet
import com.type4me.android.data.VocabularyStore
import com.type4me.android.databinding.ActivityHotwordsBinding
import com.type4me.android.databinding.ItemWordBinding

class HotwordsActivity : AppCompatActivity() {

    private lateinit var binding: ActivityHotwordsBinding
    private var hotwords: List<String> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivityHotwordsBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyInsets()

        binding.back.setOnClickListener { finish() }
        binding.addHotword.setOnClickListener { add() }
        binding.hotwordInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                add()
                true
            } else {
                false
            }
        }
        load()
    }

    private fun applyInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime())
            binding.toolbar.applyNavBarTopInset(bars.top)
            view.updatePadding(bottom = maxOf(bars.bottom, keyboard.bottom))
            insets
        }
    }

    private fun load() {
        hotwords = VocabularyStore.hotwords(this)
        binding.hotwordList.removeAllViews()
        binding.listCard.isVisible = hotwords.isNotEmpty()
        hotwords.forEach { word ->
            addDivider()
            val row = ItemWordBinding.inflate(layoutInflater, binding.hotwordList, false)
            row.word.text = word
            row.delete.setOnClickListener {
                VocabularyStore.save(this, hotwords - word, VocabularyStore.snippets(this))
                binding.notice.isVisible = false
                load()
            }
            binding.hotwordList.addView(row.root)
        }
    }

    private fun add() {
        val word = binding.hotwordInput.text?.toString()?.trim().orEmpty()
        if (word.isEmpty()) return
        if (hotwords.any { it.equals(word, ignoreCase = true) }) {
            binding.notice.setText(R.string.hotword_exists)
            binding.notice.isVisible = true
            return
        }
        write(hotwords + word)
        binding.hotwordInput.setText("")
        binding.notice.isVisible = false
        load()
        Toast.makeText(this, R.string.saved, Toast.LENGTH_SHORT).show()
    }

    private fun write(words: List<String>) {
        VocabularyStore.save(this, words, VocabularyStore.snippets(this))
    }

    private fun addDivider() {
        if (binding.hotwordList.childCount == 0) return
        binding.hotwordList.addView(
            View(this).apply { setBackgroundColor(getColor(R.color.divider)) },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(1),
            ).apply { marginStart = dp(16) },
        )
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
