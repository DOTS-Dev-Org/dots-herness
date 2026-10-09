package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlanningIntentTest {
    @Test
    fun planningRequestsActivatePlanMode() {
        assertTrue(MobilePlanningIntent.shouldEnterPlanMode("Bu dosya için bir plan hazırla"))
        assertTrue(MobilePlanningIntent.shouldEnterPlanMode("I need a plan for this file"))
        assertTrue(MobilePlanningIntent.shouldEnterPlanMode("Write the plan to plan.md"))
        assertTrue(MobilePlanningIntent.shouldEnterPlanMode("Sadece sohbette plan yap"))
        assertTrue(MobilePlanningIntent.shouldEnterPlanMode("Plan moduna geç"))
        assertTrue(MobilePlanningIntent.shouldEnterPlanMode("Switch to plan mode"))
        assertTrue(MobilePlanningIntent.shouldEnterPlanMode("/plan add OAuth"))
    }

    @Test
    fun approvalsAndReferencesDoNotActivatePlanMode() {
        assertFalse(MobilePlanningIntent.shouldEnterPlanMode("Planı uygula"))
        assertFalse(MobilePlanningIntent.shouldEnterPlanMode("Read plan.md"))
        assertFalse(MobilePlanningIntent.shouldEnterPlanMode("Explain what plan mode is"))
    }

    @Test
    fun wordsThatOnlyMentionAPlanAreAmbiguous() {
        assertEquals(PlanVerdict.AMBIGUOUS, MobilePlanningIntent.verdict("Bu dosyanın planını çıkar"))
        assertEquals(PlanVerdict.AMBIGUOUS, MobilePlanningIntent.verdict("Make a planet texture"))
        assertEquals(PlanVerdict.AMBIGUOUS, MobilePlanningIntent.verdict("Read plan.md"))
        assertEquals(PlanVerdict.NO, MobilePlanningIntent.verdict("Fix the login bug"))
        assertFalse(MobilePlanningIntent.shouldEnterPlanMode("Make a planet texture"))
    }
}
