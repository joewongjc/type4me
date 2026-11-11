package com.type4me.android.pipeline

import android.content.Context

/** The Mac and iPhone translation targets, in the same order. */
enum class TranslateTarget(
    val code: String,
    val englishName: String,
    val chineseName: String,
) {
    ENGLISH("en", "English", "英语"),
    SIMPLIFIED_CHINESE("zh-Hans", "Simplified Chinese", "简体中文"),
    TRADITIONAL_CHINESE("zh-Hant", "Traditional Chinese", "繁体中文"),
    JAPANESE("ja", "Japanese", "日语"),
    KOREAN("ko", "Korean", "韩语"),
    SPANISH("es", "Spanish", "西班牙语"),
    FRENCH("fr", "French", "法语"),
    GERMAN("de", "German", "德语"),
    BRAZILIAN_PORTUGUESE("pt-BR", "Portuguese (Brazil)", "葡萄牙语（巴西）"),
    ITALIAN("it", "Italian", "意大利语"),
    RUSSIAN("ru", "Russian", "俄语"),
    ARABIC("ar", "Arabic", "阿拉伯语"),
    HINDI("hi", "Hindi", "印地语"),
    THAI("th", "Thai", "泰语"),
    VIETNAMESE("vi", "Vietnamese", "越南语"),
    INDONESIAN("id", "Indonesian", "印度尼西亚语"),
    TURKISH("tr", "Turkish", "土耳其语"),
    DUTCH("nl", "Dutch", "荷兰语");

    fun label(context: Context): String =
        if (context.resources.configuration.locales[0].language == "zh") chineseName else englishName

    /** The short tag for the mode pill, following the app language. */
    fun shortTag(chinese: Boolean): String {
        if (chinese) {
            return when (this) {
                SIMPLIFIED_CHINESE -> "简中"
                TRADITIONAL_CHINESE -> "繁中"
                BRAZILIAN_PORTUGUESE -> "PT"
                else -> code.uppercase()
            }
        }
        return when (this) {
            TRADITIONAL_CHINESE -> "ZH-TW"
            BRAZILIAN_PORTUGUESE -> "PT"
            else -> code.substringBefore('-').uppercase()
        }
    }

    fun shortTag(context: Context): String =
        shortTag(context.resources.configuration.locales[0].language == "zh")

    companion object {
        fun byCode(code: String?): TranslateTarget =
            entries.firstOrNull { it.code == code } ?: ENGLISH

        /** Old stored values used the language name or a short code. */
        fun migrate(value: String?): TranslateTarget = when (value) {
            "en", "ENGLISH" -> ENGLISH
            "zh", "zh-CN", "CHINESE" -> SIMPLIFIED_CHINESE
            "ja", "JAPANESE" -> JAPANESE
            "ko", "KOREAN" -> KOREAN
            else -> byCode(value)
        }
    }
}
