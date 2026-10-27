package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MarkdownDiagramsTest {
    @Test
    fun fenceLanguageIsKept() {
        assertEquals(MarkdownSegment(true, "A | B", "diagram"), splitMarkdownSegments("a\n```diagram\nA | B\n```")[1])
    }

    @Test
    fun flowRowsCarryNumberNoteAndBadge() {
        val steps = parseFlow("Harita: şema 4 `## x` [warn: Eski şema]\n\nBilgi: sırada [Sırada]")
        assertEquals(FlowStep(1, "Harita", "şema 4 `## x`", DiagramTag("warn", "Eski şema"), false), steps[0])
        assertEquals(FlowStep(2, "Bilgi", "sırada", DiagramTag(null, "Sırada"), true), steps[1])
    }

    @Test
    fun diagramParsesLayersCaptionsLegendAndColors() {
        val spec = DiagramSpec.parse("Kural: AGENTS.md [repo] | Kişisel: Mac [local] | Git index\n> System prompt\nModel çalışır\nlegend: repo = Repo | local = Bu Mac")
        assertEquals(listOf(3, 1), spec.layers.map { it.nodes.size })
        assertEquals("System prompt", spec.layers[1].caption)
        assertEquals(DiagramNode("Kişisel", "Mac", "local"), spec.layers[0].nodes[1])
        assertNull(spec.layers[0].nodes[2].group)
        assertEquals(listOf("repo", "local"), spec.legend.map { it.first })
        assertNotEquals(spec.color("repo"), spec.color("local"))
    }

    @Test
    fun chartScalesToPeak() {
        val bars = parseChart("macOS: 40\nnot a row\nLinux: 10 ms")
        assertEquals(listOf(1f, 0.25f), bars.map { it.fraction })
        assertEquals("10 ms", bars[1].text)
    }
}
