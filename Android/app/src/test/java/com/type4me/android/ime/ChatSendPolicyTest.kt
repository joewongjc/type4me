package com.type4me.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatSendPolicyTest {
    @Test
    fun standardSendFieldsUseSwipeToSend() {
        assertTrue(ChatSendPolicy.canSwipeSend("com.example.chat", ACTION_SEND))
        assertEquals(
            ACTION_SEND,
            ChatSendPolicy.sendAction("com.example.chat", ACTION_SEND),
        )
    }

    @Test
    fun standardDoneFieldsKeepTheirNormalBehavior() {
        assertFalse(ChatSendPolicy.canSwipeSend("com.example.editor", ACTION_DONE))
        assertNull(ChatSendPolicy.sendAction("com.example.editor", ACTION_DONE))
    }

    @Test
    fun wechatDoneFieldsUseExplicitSendForSwipe() {
        assertTrue(ChatSendPolicy.canSwipeSend("com.tencent.mm", ACTION_DONE, MULTILINE))
        assertEquals(
            ACTION_SEND,
            ChatSendPolicy.sendAction("com.tencent.mm", ACTION_DONE, MULTILINE),
        )
    }

    @Test
    fun wechatSingleLineDoneFieldsKeepTheirNormalBehavior() {
        assertFalse(ChatSendPolicy.canSwipeSend("com.tencent.mm", ACTION_DONE, SINGLE_LINE))
        assertNull(ChatSendPolicy.sendAction("com.tencent.mm", ACTION_DONE, SINGLE_LINE))
    }

    @Test
    fun wechatNonDoneFieldsAreNotChanged() {
        assertFalse(ChatSendPolicy.canSwipeSend("com.tencent.mm", ACTION_NEXT))
        assertNull(ChatSendPolicy.sendAction("com.tencent.mm", ACTION_NEXT))
    }

    @Test
    fun wechatSendStaysAvailableWhenTheSystemClearsTheAction() {
        assertEquals(
            ACTION_SEND,
            ChatSendPolicy.sendAction(
                packageName = "com.tencent.mm",
                action = ACTION_NONE,
                inputType = MULTILINE,
                wasSendSupportedAtStart = true,
            ),
        )
        assertNull(
            ChatSendPolicy.sendAction(
                packageName = "com.tencent.mm",
                action = ACTION_NONE,
                inputType = MULTILINE,
                wasSendSupportedAtStart = false,
            ),
        )
        assertEquals(
            ACTION_SEND,
            ChatSendPolicy.sendAction(
                packageName = "com.tencent.mm",
                action = ACTION_UNSPECIFIED,
                inputType = MULTILINE,
                wasSendSupportedAtStart = true,
            ),
        )
    }

    private companion object {
        const val ACTION_UNSPECIFIED = 0
        const val ACTION_NONE = 1
        const val ACTION_SEND = 4
        const val ACTION_NEXT = 5
        const val ACTION_DONE = 6
        const val MULTILINE = 0x00020001
        const val SINGLE_LINE = 0x00000001
    }
}
