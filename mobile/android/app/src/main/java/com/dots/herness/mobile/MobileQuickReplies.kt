package com.dots.herness.mobile

import java.util.Locale

data class MobileQuickReply(val text: String)

object MobileQuickReplySuggestions {
    private val optionPattern = Regex("^\\d+[.)]\\s*(.+?)\\s*$")
    private val turkishEndings = listOf(
        "uygulayayım mı" to "uygula",
        "güncelleyeyim mi" to "güncelle",
        "değiştireyim mi" to "değiştir",
        "göndereyim mi" to "gönder",
        "başlatayım mı" to "başlat",
        "ekleyeyim mi" to "ekle",
        "sileyim mi" to "sil",
        "yapayım mı" to "yap",
        "edeyim mi" to "et",
    )
    private val englishPrefixes = listOf(
        "Would you like me to ", "Do you want me to ", "Should I ",
        "Shall I ", "Can I ", "May I ",
    )

    fun choices(in assistantText: String, continueReply: String, declineReply: String): List<MobileQuickReply> {
        val lines = assistantText.lines()
        val question = lines.lastOrNull(String::isNotBlank)?.trim().orEmpty()
        if (question.lastOrNull() !in setOf('?', '？', '؟')) return emptyList()

        val options = lines.mapNotNull { line ->
            optionPattern.matchEntire(line.trim())?.groupValues?.getOrNull(1)?.let(::normalize)
        }.filter(String::isNotEmpty).distinctBy { it.lowercase(Locale.ROOT) }.take(2).map { it.take(200) }
        if (options.isNotEmpty()) {
            val choices = options.toMutableList()
            if (choices.size == 1 && declineReply.isNotEmpty()) choices += declineReply
            return choices.map(::MobileQuickReply)
        }

        val affirmative = affirmativeReply(question, continueReply) ?: return emptyList()
        return listOf(affirmative, declineReply).filter(String::isNotEmpty).take(2).map(::MobileQuickReply)
    }

    private fun affirmativeReply(question: String, fallback: String): String? {
        val body = question.dropLast(1).trim()
        val lower = body.lowercase(Locale.ROOT)
        val ending = turkishEndings.firstOrNull { lower.endsWith(it.first.lowercase(Locale.ROOT)) }
        if (ending != null) return finish(body.dropLast(ending.first.length) + ending.second)

        val prefix = englishPrefixes.firstOrNull { body.startsWith(it, ignoreCase = true) } ?: return null
        val action = body.drop(prefix.length).trim()
        return if (action.isEmpty()) fallback else finish(action)
    }

    private fun normalize(value: String): String = value.split(Regex("\\s+")).filter(String::isNotEmpty).joinToString(" ")

    private fun finish(value: String): String {
        val text = value.trim().replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }
        return if (text.endsWith('.')) text else "$text."
    }
}
