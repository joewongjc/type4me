package com.type4me.android.ime

import android.view.inputmethod.EditorInfo

/**
 * Android normally reports a chat composer's send affordance through
 * IME_ACTION_SEND. WeChat can instead report IME_ACTION_DONE while still
 * accepting an explicit send request, so swipe-to-send treats a WeChat
 * "Done" field that was send-capable when recording began as send-capable.
 * The declared "Done" label is left untouched.
 */
internal object ChatSendPolicy {
    private const val WECHAT_PACKAGE = "com.tencent.mm"
    private const val ACTION_NONE = 1
    private const val ACTION_UNSPECIFIED = 0
    private const val ACTION_DONE = 6
    private const val ACTION_SEND = 4
    private const val TYPE_TEXT_FLAG_MULTI_LINE = 0x00020000

    fun canSwipeSend(info: EditorInfo?): Boolean =
        canSwipeSend(info?.packageName?.toString(), action(info), inputType(info))

    fun sendAction(info: EditorInfo?, wasSendSupportedAtStart: Boolean): Int? =
        sendAction(
            info?.packageName?.toString(),
            action(info),
            inputType(info),
            wasSendSupportedAtStart,
        )

    internal fun canSwipeSend(
        packageName: String?,
        action: Int,
        inputType: Int = TYPE_TEXT_FLAG_MULTI_LINE,
    ): Boolean = sendAction(packageName, action, inputType) != null

    internal fun sendAction(
        packageName: String?,
        action: Int,
        inputType: Int = TYPE_TEXT_FLAG_MULTI_LINE,
        wasSendSupportedAtStart: Boolean = false,
    ): Int? = resolve(packageName, action, inputType, wasSendSupportedAtStart)

    internal fun resolve(
        packageName: String?,
        action: Int,
        inputType: Int,
        wasSendSupportedAtStart: Boolean = false,
    ): Int? = when {
        action == ACTION_SEND -> ACTION_SEND
        packageName == WECHAT_PACKAGE && isMultiLine(inputType) && wasSendSupportedAtStart &&
            (action == ACTION_NONE || action == ACTION_UNSPECIFIED) ->
            ACTION_SEND

        packageName == WECHAT_PACKAGE && isMultiLine(inputType) && action == ACTION_DONE ->
            ACTION_SEND

        else -> null
    }

    private fun action(info: EditorInfo?): Int =
        info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: ACTION_NONE

    private fun inputType(info: EditorInfo?): Int = info?.inputType ?: 0

    private fun isMultiLine(inputType: Int): Boolean =
        inputType and TYPE_TEXT_FLAG_MULTI_LINE != 0
}
