package com.type4me.android.data

/** What a scanned Mac setup should bring over. */
data class ImportSelection(
    var asrs: MutableSet<String> = mutableSetOf(),
    var activeAsr: String? = null,
    var llms: MutableSet<String> = mutableSetOf(),
    var activeLlm: String? = null,
    var modes: MutableSet<String> = mutableSetOf(),
    var hotwords: Boolean = false,
    var snippets: Boolean = false,
    var textOutput: Boolean = false,
) {
    companion object {
        fun all(payload: TransferPayload): ImportSelection = ImportSelection(
            asrs = payload.allAsrs.mapTo(mutableSetOf()) { it.provider },
            activeAsr = payload.allAsrs.firstOrNull()?.provider,
            llms = payload.allLlms.mapTo(mutableSetOf()) { it.provider },
            activeLlm = payload.allLlms.firstOrNull()?.provider,
            modes = payload.modes.mapTo(mutableSetOf()) { it.id },
            hotwords = !payload.hotwords.isNullOrEmpty(),
            snippets = !payload.snippets.isNullOrEmpty(),
            textOutput = payload.textOutput != null,
        )
    }
}
