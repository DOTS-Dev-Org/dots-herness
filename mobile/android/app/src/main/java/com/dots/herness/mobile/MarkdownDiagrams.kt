// Copyright (c) 2026 DOTS
// Colored ```diagram, ```flow and ```chart fences; same rules as shared/MarkdownDiagrams.cs.
package com.dots.herness.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** A trailing `[tone: label]` or `[group]` tag. */
data class DiagramTag(val tone: String?, val label: String) {
    val color: Color get() = tone?.let { statusColor(it) } ?: NEUTRAL

    companion object {
        val NEUTRAL = Color(0xFF8E8E93)
        private val PALETTE = listOf(
            Color(0xFF30B0C7), Color(0xFF5856D6), Color(0xFFFF9500),
            Color(0xFFFF2D55), Color(0xFF007AFF), Color(0xFFA2845E),
        )

        fun statusColor(name: String): Color? = when (name.lowercase()) {
            "ok", "done" -> Color(0xFF34C759)
            "warn", "warning" -> Color(0xFFFF9500)
            "error", "fail" -> Color(0xFFFF3B30)
            "info" -> Color(0xFF007AFF)
            "pending" -> NEUTRAL
            else -> null
        }

        fun paletteColor(slot: Int): Color = PALETTE[slot % PALETTE.size]

        /** `"Title: note [ok: Doğru]"` → `"Title: note"` to the tag. */
        fun split(line: String): Pair<String, DiagramTag?> {
            val trimmed = line.trim()
            val open = trimmed.lastIndexOf('[')
            if (!trimmed.endsWith("]") || open < 0) return trimmed to null
            val inner = trimmed.substring(open + 1, trimmed.length - 1)
            val body = trimmed.substring(0, open).trim()
            val first = inner.substringBefore(':').trim()
            if (first.isEmpty()) return body to null
            if (':' in inner) return body to DiagramTag(first, inner.substringAfter(':').trim())
            return body to DiagramTag(if (statusColor(first) != null) first else null, first)
        }

        fun titleNote(body: String): Pair<String, String> =
            body.substringBefore(':').trim() to (if (':' in body) body.substringAfter(':').trim() else "")
    }
}

data class FlowStep(val number: Int, val title: String, val note: String, val badge: DiagramTag?, val isLast: Boolean)
data class ChartBar(val label: String, val text: String, val fraction: Float)
data class DiagramNode(val title: String, val note: String, val group: String?)
data class DiagramLayer(val caption: String?, val nodes: List<DiagramNode>)

/** ```diagram: one line per layer; `a: b [g] | c: d [g]`, `> caption`, `legend: g = text | …`. */
data class DiagramSpec(val layers: List<DiagramLayer>, val legend: List<Pair<String, String>>) {
    /** Status names keep their fixed color; other groups take palette slots by first use. */
    fun color(group: String?): Color {
        if (group.isNullOrEmpty()) return DiagramTag.NEUTRAL
        DiagramTag.statusColor(group)?.let { return it }
        val seen = (layers.flatMap { layer -> layer.nodes.mapNotNull { it.group } } + legend.map { it.first })
            .filter { DiagramTag.statusColor(it) == null }.distinct()
        return DiagramTag.paletteColor(seen.indexOf(group).coerceAtLeast(0))
    }

    companion object {
        fun parse(source: String): DiagramSpec {
            val layers = mutableListOf<DiagramLayer>()
            val legend = mutableListOf<Pair<String, String>>()
            var caption: String? = null
            for (raw in source.split("\n")) {
                val line = raw.trim()
                when {
                    line.isEmpty() -> Unit
                    line.startsWith(">") -> caption = line.drop(1).trim()
                    line.lowercase().startsWith("legend:") -> line.drop(7).split("|").forEach { item ->
                        if ('=' in item) legend += item.substringBefore('=').trim() to item.substringAfter('=').trim()
                    }
                    else -> {
                        layers += DiagramLayer(caption, line.split("|").map { cell ->
                            val (body, tag) = DiagramTag.split(cell)
                            val (title, note) = DiagramTag.titleNote(body)
                            DiagramNode(title, note, tag?.label)
                        })
                        caption = null
                    }
                }
            }
            return DiagramSpec(layers, legend)
        }
    }
}

fun parseFlow(source: String): List<FlowStep> {
    val lines = source.split("\n").filter { it.isNotBlank() }
    return lines.mapIndexed { index, line ->
        val (body, badge) = DiagramTag.split(line)
        val (title, note) = DiagramTag.titleNote(body)
        FlowStep(index + 1, title, note, badge, index == lines.lastIndex)
    }
}

/** `label: number` rows scaled to the block's peak; other lines are skipped. */
fun parseChart(source: String): List<ChartBar> {
    val rows = source.split("\n").mapNotNull { raw ->
        val colon = raw.lastIndexOf(':')
        if (colon < 0) return@mapNotNull null
        val text = raw.substring(colon + 1).trim()
        val value = text.takeWhile { it.isDigit() || it == '.' || it == '-' }.toDoubleOrNull() ?: return@mapNotNull null
        Triple(raw.substring(0, colon).trim(), text, value)
    }
    val peak = rows.maxOfOrNull { kotlin.math.abs(it.third) } ?: 0.0
    return rows.map { ChartBar(it.first, it.second, if (peak > 0) (kotlin.math.abs(it.third) / peak).toFloat() else 0f) }
}

private fun plain(text: String) = text.replace("`", "")

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DiagramBlock(spec: DiagramSpec) {
    val outline = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
    Column(
        Modifier.fillMaxWidth().border(1.dp, outline, RoundedCornerShape(10.dp)).padding(10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        spec.layers.forEachIndexed { index, layer ->
            if (index > 0) Text("↓", color = DiagramTag.NEUTRAL)
            layer.caption?.let {
                Text(plain(it), Modifier.fillMaxWidth(), style = MaterialTheme.typography.labelSmall, color = DiagramTag.NEUTRAL)
            }
            BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                // A phone fits about three boxes per row; more stack vertically.
                if (layer.nodes.size == 1) {
                    DiagramNodeBox(layer.nodes[0], spec, Modifier.widthIn(max = 360.dp).fillMaxWidth())
                } else if (maxWidth / layer.nodes.size >= 100.dp) {
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        layer.nodes.forEach { DiagramNodeBox(it, spec, Modifier.weight(1f).fillMaxHeight()) }
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        layer.nodes.forEach { DiagramNodeBox(it, spec, Modifier.fillMaxWidth()) }
                    }
                }
            }
        }
        if (spec.legend.isNotEmpty()) {
            FlowRow(
                Modifier.padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally),
            ) {
                spec.legend.forEach { (group, text) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Spacer(Modifier.size(12.dp).background(spec.color(group).copy(alpha = 0.5f), RoundedCornerShape(3.dp)))
                        Text(plain(text), Modifier.padding(start = 6.dp), style = MaterialTheme.typography.labelSmall, color = DiagramTag.NEUTRAL)
                    }
                }
            }
        }
    }
}

@Composable
private fun DiagramNodeBox(node: DiagramNode, spec: DiagramSpec, modifier: Modifier) {
    val tint = spec.color(node.group)
    val shape = RoundedCornerShape(8.dp)
    Column(
        modifier.background(tint.copy(alpha = 0.14f), shape).border(1.dp, tint.copy(alpha = 0.45f), shape)
            .padding(horizontal = 8.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(plain(node.title), fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium)
        if (node.note.isNotEmpty()) {
            Text(plain(node.note), color = tint, textAlign = TextAlign.Center, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
fun FlowBlock(steps: List<FlowStep>) {
    Column(Modifier.fillMaxWidth()) {
        steps.forEach { step ->
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("${step.number}", Modifier.width(18.dp), color = DiagramTag.NEUTRAL, textAlign = TextAlign.End)
                Column(Modifier.weight(1f)) {
                    Text(plain(step.title), fontWeight = FontWeight.SemiBold)
                    if (step.note.isNotEmpty()) Text(plain(step.note), color = DiagramTag.NEUTRAL)
                }
                step.badge?.let { badge ->
                    Text(
                        badge.label,
                        Modifier.background(badge.color.copy(alpha = 0.15f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 2.dp),
                        color = badge.color,
                        fontWeight = FontWeight.Medium,
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
            if (!step.isLast) HorizontalDivider(Modifier.padding(start = 28.dp))
        }
    }
}

@Composable
fun ChartBlock(bars: List<ChartBar>) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        bars.forEach { bar ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(bar.label, Modifier.width(110.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                LinearProgressIndicator(progress = { bar.fraction }, modifier = Modifier.weight(1f))
                Text(bar.text, color = DiagramTag.NEUTRAL)
            }
        }
    }
}
