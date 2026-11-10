package com.type4me.android

import android.os.Bundle
import android.view.View
import android.widget.LinearLayout
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.data.Snippet
import com.type4me.android.data.VocabularyStore
import com.type4me.android.databinding.ActivitySnippetsBinding
import com.type4me.android.databinding.DialogSnippetBinding
import com.type4me.android.databinding.ItemSnippetBinding

class SnippetsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySnippetsBinding
    private var snippets: List<Snippet> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivitySnippetsBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyInsets()

        binding.back.setOnClickListener { finish() }
        binding.addSnippet.setOnClickListener { edit(index = null, snippet = null) }
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
        snippets = VocabularyStore.snippets(this)
        binding.snippetList.removeAllViews()
        binding.listCard.isVisible = snippets.isNotEmpty()
        snippets.forEachIndexed { index, snippet ->
            addDivider()
            val row = ItemSnippetBinding.inflate(layoutInflater, binding.snippetList, false)
            row.trigger.text = snippet.trigger
            row.replacement.text = getString(R.string.snippet_arrow_format, snippet.replacement)
            row.row.setOnClickListener { edit(index, snippet) }
            row.delete.setOnClickListener { remove(index) }
            binding.snippetList.addView(row.root)
        }
    }

    private fun remove(index: Int) {
        val updated = snippets.toMutableList().apply { removeAt(index) }
        VocabularyStore.save(this, VocabularyStore.hotwords(this), updated)
        binding.notice.isVisible = false
        load()
    }

    private fun edit(index: Int?, snippet: Snippet?) {
        val view = DialogSnippetBinding.inflate(layoutInflater)
        view.snippetTrigger.setText(snippet?.trigger.orEmpty())
        view.snippetReplacement.setText(snippet?.replacement.orEmpty())

        val dialog = MaterialAlertDialogBuilder(this)
            .setTitle(if (index == null) R.string.add_snippet else R.string.edit_snippet)
            .setView(view.root)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.save, null)
            .create()

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val trigger = view.snippetTrigger.text?.toString()?.trim().orEmpty()
                val replacement = view.snippetReplacement.text?.toString()?.trim().orEmpty()
                if (trigger.isEmpty()) {
                    view.snippetTriggerLayout.error = getString(R.string.snippet_trigger_hint)
                    return@setOnClickListener
                }
                val duplicate = snippets.withIndex().any { (position, existing) ->
                    position != index && existing.trigger.equals(trigger, ignoreCase = true)
                }
                if (duplicate) {
                    Toast.makeText(this, R.string.snippet_exists, Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }
                val updated = snippets.toMutableList()
                if (index == null) {
                    updated.add(Snippet(trigger, replacement))
                } else {
                    updated[index] = Snippet(trigger, replacement)
                }
                VocabularyStore.save(this, VocabularyStore.hotwords(this), updated)
                binding.notice.isVisible = false
                dialog.dismiss()
                load()
            }
        }
        dialog.show()
    }

    private fun addDivider() {
        if (binding.snippetList.childCount == 0) return
        binding.snippetList.addView(
            View(this).apply { setBackgroundColor(getColor(R.color.divider)) },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(1),
            ).apply { marginStart = dp(16) },
        )
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
