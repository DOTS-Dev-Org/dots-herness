package com.dots.herness.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * One piece of a chat message: prose, or the body of a ``` fence; [language] is the fence tag.
 * A pipe table in prose comes out as code with language `table`; read it with [parseMarkdownTable].
 */
data class MarkdownSegment(val isCode: Boolean, val text: String, val language: String = "")

enum class MarkdownTableAlignment { Start, Center, End }

data class MarkdownTable(
    val header: List<String>,
    val alignments: List<MarkdownTableAlignment>,
    val rows: List<List<String>>,
)

private fun isTableRow(line: String) = line.trimStart().startsWith("|")

// ponytail: splits on every `|`, so a pipe inside inline code breaks the cell; `\|` escapes it.
fun markdownTableCells(line: String): List<String> {
    var body = line.trim().removePrefix("|")
    if (body.endsWith("|") && !body.endsWith("\\|")) body = body.dropLast(1)
    return body.replace("\\|", "\u0000").split("|").map { it.replace("\u0000", "|").trim() }
}

/** The `|---|:--:|` row under a table header, or null when the line is anything else. */
fun markdownTableAlignments(line: String): List<MarkdownTableAlignment>? {
    if (!isTableRow(line)) return null
    val cells = markdownTableCells(line)
    if (!cells.all { cell -> '-' in cell && cell.all { it == '-' || it == ':' } }) return null
    return cells.map {
        when {
            it.startsWith(":") && it.endsWith(":") -> MarkdownTableAlignment.Center
            it.endsWith(":") -> MarkdownTableAlignment.End
            else -> MarkdownTableAlignment.Start
        }
    }
}

fun parseMarkdownTable(text: String): MarkdownTable {
    val lines = text.split("\n")
    return MarkdownTable(
        header = markdownTableCells(lines[0]),
        alignments = markdownTableAlignments(lines[1]).orEmpty(),
        rows = lines.drop(2).map(::markdownTableCells),
    )
}

/** Splits prose from fenced blocks; an unclosed fence stays code while a reply streams. */
fun splitMarkdownSegments(text: String): List<MarkdownSegment> {
    val segments = mutableListOf<MarkdownSegment>()
    val prose = mutableListOf<String>()
    val code = mutableListOf<String>()
    var inCode = false
    var language = ""

    fun addProse(lines: List<String>) {
        val body = lines.joinToString("\n").trim('\n')
        if (body.isNotBlank()) segments += MarkdownSegment(isCode = false, text = body)
    }

    // A table header still waiting for its `|---|` row stays prose until that row streams in.
    fun flushProse() {
        var start = 0
        var i = 0
        while (i + 1 < prose.size) {
            if (!isTableRow(prose[i]) || markdownTableAlignments(prose[i + 1]) == null) {
                i++
                continue
            }
            var end = i + 2
            while (end < prose.size && isTableRow(prose[end])) end++
            addProse(prose.subList(start, i))
            segments += MarkdownSegment(true, prose.subList(i, end).joinToString("\n") { it.trim() }, "table")
            start = end
            i = end
        }
        addProse(prose.subList(start, prose.size))
        prose.clear()
    }

    fun flushCode() {
        if (code.isNotEmpty()) segments += MarkdownSegment(isCode = true, text = code.joinToString("\n"), language = language)
        code.clear()
    }

    for (line in text.replace("\r\n", "\n").split("\n")) {
        if (line.trimStart().startsWith("```")) {
            if (inCode) {
                flushCode()
            } else {
                flushProse()
                language = line.trim().removePrefix("```").trim().lowercase()
            }
            inCode = !inCode
        } else if (inCode) {
            code += line
        } else {
            prose += line
        }
    }
    if (inCode) flushCode() else flushProse()
    return segments
}

/** Chat message body: prose wraps; fenced blocks stay unwrapped so box diagrams keep their columns. */
@Composable
fun MarkdownBody(text: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        splitMarkdownSegments(text).forEach { segment ->
            when {
                !segment.isCode -> Text(segment.text)
                segment.language == "diagram" -> DiagramBlock(DiagramSpec.parse(segment.text))
                segment.language == "flow" -> FlowBlock(parseFlow(segment.text))
                segment.language == "chart" && parseChart(segment.text).isNotEmpty() -> ChartBlock(parseChart(segment.text))
                segment.language == "table" -> TableBlock(parseMarkdownTable(segment.text))
                else -> MarkdownCodeBlock(segment.text)
            }
        }
    }
}

/** Equal-width columns so long cells wrap instead of overflowing the bubble. */
@Composable
private fun TableBlock(table: MarkdownTable) {
    val line = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.15f)
    val shape = RoundedCornerShape(8.dp)
    Column(Modifier.fillMaxWidth().clip(shape).border(1.dp, line, shape)) {
        (listOf(table.header) + table.rows).forEachIndexed { index, cells ->
            if (index > 0) HorizontalDivider(color = line)
            val header = index == 0
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(if (header) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f) else Color.Transparent),
            ) {
                table.header.indices.forEach { column ->
                    Text(
                        cells.getOrElse(column) { "" }.replace("**", "").replace("`", ""),
                        modifier = Modifier.weight(1f).padding(horizontal = 8.dp, vertical = 6.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = if (header) FontWeight.SemiBold else null,
                        textAlign = when (table.alignments.getOrNull(column)) {
                            MarkdownTableAlignment.Center -> TextAlign.Center
                            MarkdownTableAlignment.End -> TextAlign.End
                            else -> TextAlign.Start
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun MarkdownCodeBlock(code: String) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_500)
            copied = false
        }
    }
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f), RoundedCornerShape(8.dp)),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 8.dp, top = 4.dp, end = 4.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            IconButton(onClick = {
                clipboard.setText(AnnotatedString(code))
                copied = true
            }) {
                Icon(
                    if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                    contentDescription = stringResource(R.string.conversation_copy),
                )
            }
        }
        Text(
            code,
            modifier = Modifier
                .horizontalScroll(rememberScrollState())
                .padding(start = 10.dp, end = 10.dp, bottom = 8.dp),
            fontFamily = FontFamily.Monospace,
            softWrap = false,
        )
    }
}
