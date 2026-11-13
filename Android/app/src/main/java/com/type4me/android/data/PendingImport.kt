package com.type4me.android.data

/** The scanned setup waiting for the user to choose what to import. */
object PendingImport {
    @Volatile
    var payload: TransferPayload? = null

    fun clear() {
        payload = null
    }
}
