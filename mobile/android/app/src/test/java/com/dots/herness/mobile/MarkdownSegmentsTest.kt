package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownSegmentsTest {
    @Test
    fun fencedBlockSplitsFromProseAndKeepsItsColumns() {
        assertEquals(
            listOf(
                MarkdownSegment(isCode = false, text = "Akış:"),
                MarkdownSegment(isCode = true, text = "┌─┐\n└─┘"),
                MarkdownSegment(isCode = false, text = "Son"),
            ),
            splitMarkdownSegments("Akış:\n```\n┌─┐\n└─┘\n```\nSon"),
        )
    }

    @Test
    fun unclosedFenceStaysCodeWhileAReplyStreams() {
        assertEquals(listOf(MarkdownSegment(isCode = true, text = "┌─┐")), splitMarkdownSegments("```\n┌─┐"))
    }

    @Test
    fun plainTextIsOneProseSegment() {
        assertEquals(listOf(MarkdownSegment(isCode = false, text = "merhaba")), splitMarkdownSegments("merhaba"))
    }

    @Test
    fun pipeTableBecomesItsOwnSegment() {
        val segments = splitMarkdownSegments("Fark:\n| Özellik | `actor` | x |\n|---|:---:|--:|\n| Tür | a \\| b | 1 |\n| Kalıtım | yok |\nSon")
        assertEquals(3, segments.size)
        assertEquals("table", segments[1].language)
        val table = parseMarkdownTable(segments[1].text)
        assertEquals(listOf("Özellik", "`actor`", "x"), table.header)
        assertEquals(
            listOf(MarkdownTableAlignment.Start, MarkdownTableAlignment.Center, MarkdownTableAlignment.End),
            table.alignments,
        )
        assertEquals(listOf(listOf("Tür", "a | b", "1"), listOf("Kalıtım", "yok")), table.rows)
        assertEquals(MarkdownSegment(isCode = false, text = "Son"), segments[2])
    }

    @Test
    fun tableHeaderWithoutSeparatorStaysProse() {
        assertEquals(listOf(MarkdownSegment(isCode = false, text = "| a | b |")), splitMarkdownSegments("| a | b |"))
    }
}
