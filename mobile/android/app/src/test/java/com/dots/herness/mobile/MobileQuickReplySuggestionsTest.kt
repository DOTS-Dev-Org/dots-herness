package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileQuickReplySuggestionsTest {
    @Test
    fun turkishConfirmationProducesActionAndDeclineReplies() {
        val replies = MobileQuickReplySuggestions.choices(
            "main'i origin'e push edeyim mi?",
            "Devam et",
            "Reddet",
        ).map { it.text }

        assertEquals(listOf("Main'i origin'e push et.", "Reddet"), replies)
    }

    @Test
    fun numberedRecommendationsBecomeReplies() {
        val replies = MobileQuickReplySuggestions.choices(
            "1. Update the route\n2) Keep the existing route\nShould I apply one?",
            "Continue",
            "Reject",
        ).map { it.text }

        assertEquals(listOf("Update the route", "Keep the existing route"), replies)
    }

    @Test
    fun onlyActionConfirmationQuestionsOfferReplies() {
        assertTrue(MobileQuickReplySuggestions.choices("Does this look correct?", "Continue", "Reject").isEmpty())
    }
}
