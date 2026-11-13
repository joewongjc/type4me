package com.type4me.android.asr

/** Builds a Volcengine server frame with a JSON result payload. */
internal fun volcServerFrame(text: String, final: Boolean): ByteArray {
    val payload = """{"result":{"text":"$text"}}""".toByteArray()
    val message = ByteArray(8 + payload.size)
    message[0] = 0x11
    message[1] = ((9 shl 4) or (if (final) 4 else 0)).toByte()
    message[2] = 0x10
    message[3] = 0
    message[4] = (payload.size ushr 24).toByte()
    message[5] = (payload.size ushr 16).toByte()
    message[6] = (payload.size ushr 8).toByte()
    message[7] = payload.size.toByte()
    payload.copyInto(message, 8)
    return message
}
