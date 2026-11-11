package com.paperreader.pdf

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Turns a paper PDF into an ordered list of text lines with bounding boxes.
 *
 * Steps per page:
 *  1. Extract words with positions (PdfBox).
 *  2. Group words into line fragments (same baseline, small horizontal gap).
 *  3. Detect two-column layout and order lines: full-width lines split the
 *     page into bands; inside a band the left column is read before the right.
 * Then across the document: drop running headers/footers and page numbers,
 * and tag each line as body / heading / caption / small (figure labels etc).
 *
 * Output coordinates are normalized to 0..1 of the page size.
 */
object PaperAnalyzer {
    const val VERSION = 17

    // Column codes in the output.
    private const val COL_FULL = 0
    private const val COL_LEFT = 1
    private const val COL_RIGHT = 2

    class Word(
        val text: String, val x0: Float, val y0: Float, val x1: Float, val y1: Float,
        val baseline: Float, val size: Float, val bold: Boolean, val mono: Boolean = false,
    )

    class Line(first: Word) {
        val words = mutableListOf(first)
        var x0 = first.x0; var y0 = first.y0; var x1 = first.x1; var y1 = first.y1
        val baseline = first.baseline
        var size = first.size
        var col = COL_FULL
        var kind = "body"
        var isTableRow = false
        var captionStart = false
        var floatId = -1

        fun add(w: Word) {
            words.add(w)
            x0 = min(x0, w.x0); y0 = min(y0, w.y0); x1 = max(x1, w.x1); y1 = max(y1, w.y1)
            size = max(size, w.size)
        }

        val text: String get() = words.joinToString(" ") { it.text }
        val charCount: Int get() = words.sumOf { it.text.length }
        val boldShare: Float get() = words.filter { it.bold }.sumOf { it.text.length }.toFloat() / max(1, charCount)
        val mainSize: Float get() = words.maxByOrNull { it.text.length }?.size ?: size
        val monoShare: Float get() = words.filter { it.mono }.sumOf { it.text.length }.toFloat() / max(1, charCount)
    }

    /** gutters: x positions of column gaps found on the page (empty = use the page middle). */
    class PageResult(
        val index: Int, val w: Float, val h: Float, val lines: List<Line>,
        val gutters: List<Float> = emptyList(),
    )

    private class WordStripper : PDFTextStripper() {
        val words = ArrayList<Word>()

        override fun writeString(text: String, textPositions: MutableList<TextPosition>) {
            var run = ArrayList<TextPosition>()
            for (tp in textPositions) {
                if (tp.unicode.isNullOrBlank()) {
                    flush(run); run = ArrayList()
                } else {
                    run.add(tp)
                }
            }
            flush(run)
        }

        private fun flush(run: List<TextPosition>) {
            if (run.isEmpty()) return
            // Skip rotated text, e.g. the vertical arXiv stamp in the margin.
            if (run[0].dir != 0f) return
            var x0 = Float.MAX_VALUE; var x1 = -Float.MAX_VALUE
            var top = Float.MAX_VALUE; var bottom = -Float.MAX_VALUE
            var size = 0f; var baseline = 0f
            // A drop cap inside a word ("N" + "orma"): place the word by its other letters.
            val sizes = run.map { effectiveSize(it) }
            val measured = if (run.size >= 2 && sizes[0] >= 1.8f * sizes.drop(1).max()) run.drop(1) else run
            x0 = run[0].xDirAdj
            for (tp in measured) {
                val fs = effectiveSize(tp)
                x0 = min(x0, tp.xDirAdj)
                x1 = max(x1, tp.xDirAdj + tp.widthDirAdj)
                top = min(top, tp.yDirAdj - fs * 0.78f)
                bottom = max(bottom, tp.yDirAdj + fs * 0.22f)
                if (fs >= size) { size = fs; baseline = tp.yDirAdj }
            }
            val fontName = try { run[0].font?.name ?: "" } catch (_: Exception) { "" }
            val bold = fontName.contains("Bold", true) || fontName.contains("Black", true) ||
                Regex("CMBX|\\.B$|-B$|Semibold|Heavy", RegexOption.IGNORE_CASE).containsMatchIn(fontName)
            val mono = Regex("Mono|Courier|Consol|Inconsolata|CMTT|Code", RegexOption.IGNORE_CASE).containsMatchIn(fontName)
            words.add(Word(run.joinToString("") { it.unicode }, x0, top, x1, bottom, baseline, size, bold, mono))
        }

        private fun effectiveSize(tp: TextPosition): Float {
            // Rendered size from the text matrix; getFontSizeInPt is rounded to whole points.
            val y = abs(tp.yScale)
            if (y in 2f..200f) return y
            val s = tp.fontSizeInPt
            return if (s in 2f..200f) s else max(tp.heightDir * 1.4f, 6f)
        }
    }

    fun analyze(file: File, onProgress: (Float) -> Unit): String {
        PDDocument.load(file).use { doc ->
            val n = doc.numberOfPages
            val pages = ArrayList<PageResult>(n)
            for (i in 0 until n) {
                val page = doc.getPage(i)
                val box = page.cropBox
                val stripper = WordStripper().apply {
                    sortByPosition = false
                    startPage = i + 1
                    endPage = i + 1
                }
                stripper.getText(doc)
                val gutters = findGutters(stripper.words, box.width)
                val (dropCaps, words) = splitDropCaps(stripper.words)
                val built = buildLines(words, gutters)
                attachDropCaps(dropCaps, built)
                val lines = mergeTableRows(built, box.width, gutters)
                pages.add(PageResult(i, box.width, box.height, orderReading(lines, box.width, gutters), gutters))
                onProgress((i + 1f) / n * 0.95f)
            }
            removeRunningHeaders(pages)
            val bodySize = tagKinds(pages)
            val floats = detectFloats(pages, bodySize)
            return toJson(pages, bodySize, floats)
        }
    }

    // ------------------------------------------------------------ line building

    /** Typical text size on the page (the size carrying the most characters). */
    private fun typicalSize(words: List<Word>): Float {
        val hist = HashMap<Int, Int>()
        for (w in words) hist[(w.size * 2).roundToInt()] = (hist[(w.size * 2).roundToInt()] ?: 0) + w.text.length
        return (hist.maxByOrNull { it.value }?.key ?: 20) / 2f
    }

    /** Drop caps: one or two oversized letters starting a paragraph. Returns (dropCaps, otherWords). */
    private fun splitDropCaps(words: List<Word>): Pair<List<Word>, List<Word>> {
        if (words.isEmpty()) return emptyList<Word>() to words
        val typical = typicalSize(words)
        val caps = words.filter { dc ->
            dc.size >= typical * 1.8f && dc.text.length <= 2 && dc.text.first().isLetter() &&
                // Next to a drop cap is ordinary-size text, not more big title words.
                words.any { w ->
                    w !== dc && w.x0 >= dc.x1 - 1f && w.x0 <= dc.x1 + 0.8f * dc.size &&
                        w.y1 > dc.y0 && w.y0 < dc.y1 && w.size <= 0.6f * dc.size
                } &&
                words.none { w ->
                    w !== dc && w.x0 >= dc.x1 - 1f && w.x0 <= dc.x1 + 0.8f * dc.size &&
                        abs(w.baseline - dc.baseline) < 0.3f * dc.size && w.size > 0.6f * dc.size
                }
        }
        return caps to words.filter { it !in caps }
    }

    /** Puts each drop cap in front of the first word of the line it starts. */
    private fun attachDropCaps(caps: List<Word>, lines: MutableList<Line>) {
        for (dc in caps) {
            val target = lines.filter { l ->
                l.x0 >= dc.x1 - 2f && l.x0 <= dc.x1 + 3f * l.size && abs(l.y0 - dc.y0) < 1.5f * l.size
            }.minByOrNull { abs(it.y0 - dc.y0) }
            if (target == null) {
                lines.add(Line(dc))
                continue
            }
            val w0 = target.words.minByOrNull { it.x0 }!!
            val merged = Word(dc.text + w0.text, dc.x0, w0.y0, w0.x1, w0.y1, w0.baseline, w0.size, w0.bold, w0.mono)
            target.words[target.words.indexOf(w0)] = merged
            target.x0 = min(target.x0, dc.x0)
        }
    }

    private fun buildLines(words: List<Word>, gutters: List<Float>): MutableList<Line> {
        val lines = ArrayList<Line>()
        for (w in words.sortedBy { it.x0 }) {
            var best: Line? = null
            var bestScore = Float.MAX_VALUE
            for (l in lines) {
                // An oversized word must not widen the tolerance for everything around it.
                val em = min(max(w.size, l.size), 1.5f * min(w.size, l.size))
                val gap = w.x0 - l.x1
                if (gap < -0.5f * em || gap > 1.3f * em) continue
                // Never join across a column gap.
                // (A normal word space that happens to sit on the gap, in a full-width line, is fine.)
                // Across a gap, also never join text of different sizes (main text vs. side quotes).
                if (gutters.any { it >= l.x1 - 1f && it <= w.x0 + 1f }) {
                    val last = l.words.maxByOrNull { it.x1 }!!
                    val differentSize = abs(last.size - w.size) > 0.12f * max(last.size, w.size)
                    if (gap >= 0.4f * em || differentSize) continue
                }
                val dBase = abs(w.baseline - l.baseline)
                if (dBase > 0.45f * em) continue
                val score = dBase / em + max(0f, gap) / em * 0.2f
                if (score < bestScore) { bestScore = score; best = l }
            }
            if (best == null) lines.add(Line(w)) else best.add(w)
        }
        return lines
    }

    // ------------------------------------------------------------ table rows

    /**
     * Tables come out as many short cells. Cells sharing a baseline (3+ of them)
     * are merged into one row line, so one tap reads one table row.
     */
    private fun mergeTableRows(lines: List<Line>, pageW: Float, gutters: List<Float> = emptyList()): List<Line> {
        val cellMax = pageW * 0.3f
        val out = ArrayList<Line>(lines.filter { it.x1 - it.x0 >= cellMax })
        val cells = lines.filter { it.x1 - it.x0 < cellMax }.sortedBy { it.baseline }
        var row = ArrayList<Line>()
        fun mergeGroup(group: List<Line>) {
            // Only cells of similar size form a row (not e.g. a small credit line next to body text).
            val sizes = group.map { it.mainSize }.sorted()
            val med = sizes[sizes.size / 2]
            val cellsOk = group.filter { it.mainSize in (med * 0.75f)..(med * 1.33f) }
            out.addAll(group.filter { it !in cellsOk })
            val widths = cellsOk.map { it.x1 - it.x0 }.sorted()
            if (cellsOk.size >= 3 && widths[widths.size / 2] < pageW * 0.2f) {
                val sorted = cellsOk.sortedBy { it.x0 }
                val merged = Line(sorted[0].words[0])
                sorted[0].words.drop(1).forEach { merged.add(it) }
                sorted.drop(1).forEach { cell -> cell.words.forEach { merged.add(it) } }
                merged.isTableRow = true
                out.add(merged)
            } else {
                out.addAll(cellsOk)
            }
        }
        fun flush() {
            // Full-width tables may cross a column gap, so cells are matched by size only.
            mergeGroup(row)
            row = ArrayList()
        }
        for (l in cells) {
            if (row.isNotEmpty() && abs(l.baseline - row[0].baseline) > 0.35f * max(l.size, row[0].size)) flush()
            row.add(l)
        }
        if (row.isNotEmpty()) flush()
        return out
    }

    // ------------------------------------------------------------ column gaps

    /**
     * Finds column gaps anywhere on the page: vertical strips that almost no word
     * covers, with many lines ending just left of the strip and many starting just
     * right of it. Handles equal columns, a main column with a side column, etc.
     */
    private fun findGutters(words: List<Word>, pageW: Float): List<Float> {
        if (words.size < 60) return emptyList()
        val n = pageW.toInt() + 2
        val bins = IntArray(n)
        for (w in words) {
            val a = w.x0.toInt().coerceIn(0, n - 1)
            val b = w.x1.toInt().coerceIn(0, n - 1)
            for (x in a..b) bins[x]++
        }
        val x0s = words.map { it.x0 }.sorted()
        val x1s = words.map { it.x1 }.sorted()
        val left = x0s[(x0s.size * 0.03f).toInt()].toInt()
        val right = x1s[(x1s.size * 0.97f).toInt().coerceAtMost(x1s.size - 1)].toInt()
        if (right - left < pageW * 0.3f) return emptyList()
        val covered = (left..right).map { bins[it] }.sorted()
        val peak = covered[(covered.size * 0.9f).toInt().coerceAtMost(covered.size - 1)]
        if (peak < 10) return emptyList()
        val threshold = max(1, (peak * 0.12f).toInt())
        val size = words.map { it.size }.sorted()[words.size / 2]
        // Gaps can be very narrow (about 4 pt in some books); a strip that stays empty
        // down most of the page is a column gap even then.
        val minWidth = max(2.5f, 0.25f * size)
        val margin = ((right - left) * 0.1f).toInt()

        val found = ArrayList<Pair<Float, Int>>()   // center, width
        var x = left + margin
        while (x <= right - margin) {
            if (bins[x] > threshold) { x++; continue }
            val start = x
            while (x <= right - margin && bins[x] <= threshold) x++
            val end = x
            if (end - start < minWidth) continue
            val g = (start + end) / 2f
            // Column edges: lines ending just before the gap and starting just after it.
            val endingLeft = words.count { it.x1 in (start - 2.5f * size)..(start + 1f) }
            val startingRight = words.count { it.x0 in (end - 1f)..(end + 2.5f * size) }
            val leftWords = words.count { it.x1 <= start + 1f }
            val rightWords = words.count { it.x0 >= end - 1f }
            if (endingLeft >= 8 && startingRight >= 8 && leftWords >= 30 && rightWords >= 30) found.add(g to (end - start))
        }
        // Columns must be at least 12% of the page wide (rules out e.g. the strip between
        // reference numbers and reference text). Of gaps closer than that, keep the wider.
        val minCol = pageW * 0.12f
        val edgeL = x0s.first()
        val edgeR = x1s.last()
        val kept = ArrayList<Float>()
        for ((g, _) in found.sortedByDescending { it.second }) {
            if (g - edgeL >= minCol && edgeR - g >= minCol && kept.none { abs(it - g) < minCol }) kept.add(g)
        }
        return kept.sorted()
    }

    // ------------------------------------------------------------ reading order

    /** Reads columns between gaps left to right; full-width lines split the page into bands. */
    private fun orderByGutters(lines: List<Line>, gutters: List<Float>): List<Line> {
        val tol = 2f
        for (l in lines) {
            // Column = 1 + number of gaps left of the line; a line crossing a gap is full width.
            l.col = if (gutters.any { it > l.x0 + tol && it < l.x1 - tol }) COL_FULL
            else 1 + gutters.count { it <= l.x0 + tol }
        }
        val out = ArrayList<Line>(lines.size)
        val band = HashMap<Int, ArrayList<Line>>()
        fun flushBand() {
            for (c in band.keys.sorted()) out.addAll(sortRows(band[c]!!))
            band.clear()
        }
        for (l in lines.sortedBy { it.y0 }) {
            if (l.col == COL_FULL) { flushBand(); out.add(l) } else band.getOrPut(l.col) { ArrayList() }.add(l)
        }
        flushBand()
        return out
    }

    private fun orderReading(lines: List<Line>, pageW: Float, gutters: List<Float> = emptyList()): List<Line> {
        if (lines.isEmpty()) return lines
        if (gutters.isNotEmpty()) return orderByGutters(lines, gutters)
        val mid = pageW / 2f
        val tol = pageW * 0.02f
        for (l in lines) {
            l.col = when {
                l.x1 <= mid + tol -> COL_LEFT
                l.x0 >= mid - tol -> COL_RIGHT
                else -> COL_FULL
            }
        }
        // Two-column if both halves hold several substantial lines.
        val wide = pageW * 0.25f
        val leftCount = lines.count { it.col == COL_LEFT && it.x1 - it.x0 > wide }
        val rightCount = lines.count { it.col == COL_RIGHT && it.x1 - it.x0 > wide }
        val twoCol = leftCount >= 5 && rightCount >= 5

        if (!twoCol) {
            lines.forEach { it.col = COL_FULL }
            return sortRows(lines)
        }

        val out = ArrayList<Line>(lines.size)
        val left = ArrayList<Line>()
        val right = ArrayList<Line>()
        fun flushBand() {
            out.addAll(sortRows(left)); out.addAll(sortRows(right))
            left.clear(); right.clear()
        }
        for (l in lines.sortedBy { it.y0 }) {
            when (l.col) {
                COL_LEFT -> left.add(l)
                COL_RIGHT -> right.add(l)
                else -> { flushBand(); out.add(l) }
            }
        }
        flushBand()
        return out
    }

    /** Sorts top-to-bottom; lines sharing a baseline are ordered left-to-right. */
    private fun sortRows(lines: List<Line>): List<Line> {
        val byY = lines.sortedBy { it.baseline }
        val out = ArrayList<Line>(lines.size)
        var row = ArrayList<Line>()
        for (l in byY) {
            if (row.isNotEmpty() && abs(l.baseline - row[0].baseline) > 0.4f * max(l.size, row[0].size)) {
                out.addAll(row.sortedBy { it.x0 }); row = ArrayList()
            }
            row.add(l)
        }
        out.addAll(row.sortedBy { it.x0 })
        return out
    }

    // ------------------------------------------------------- headers / footers

    private fun removeRunningHeaders(pages: MutableList<PageResult>) {
        val n = pages.size
        fun inMargin(l: Line, p: PageResult) = l.y0 < p.h * 0.10f || l.y1 > p.h * 0.90f
        fun key(l: Line) = l.text.lowercase().replace(Regex("\\d+"), "#").replace(Regex("\\s+"), " ").trim()
        val pageNumber = Regex("^(page\\s*)?[#ivxlc]+(\\s*(of|/)\\s*#)?$")

        val counts = HashMap<String, Int>()
        if (n >= 3) {
            for (p in pages) {
                p.lines.filter { inMargin(it, p) }.map { key(it) }.toSet().forEach { counts[it] = (counts[it] ?: 0) + 1 }
            }
        }
        val minRepeat = max(2, (n * 0.4f).roundToInt())
        for (i in pages.indices) {
            val p = pages[i]
            val kept = p.lines.filterNot { l ->
                if (!inMargin(l, p)) return@filterNot false
                val k = key(l)
                pageNumber.matches(k) || (counts[k] ?: 0) >= minRepeat
            }
            pages[i] = PageResult(p.index, p.w, p.h, kept, p.gutters)
        }
    }

    // ------------------------------------------------------------- line kinds

    private fun tagKinds(pages: List<PageResult>): Float {
        // Body size = the font size carrying the most characters.
        val hist = HashMap<Int, Int>()
        for (p in pages) for (l in p.lines) for (w in l.words) {
            val k = (w.size * 2).roundToInt()
            hist[k] = (hist[k] ?: 0) + w.text.length
        }
        val bodySize = (hist.maxByOrNull { it.value }?.key ?: 20) / 2f
        val caption = Regex("^(fig\\.?|figure|table|tab\\.|algorithm|listing)\\s*[\\dIVX]+[a-z]?\\s*([:.|—–-]|$)", RegexOption.IGNORE_CASE)
        val numberedHeading = Regex("^(\\d+(\\.\\d+)*\\.?|[IVX]+\\.|[A-Z]\\.)\\s+\\S")

        for (p in pages) {
            // Columns whose upper part is mostly body-size text. Small text at the bottom of
            // such a column is a footnote; in a column of small text (references) it is not.
            val bodyCols = p.lines.filter { it.y0 <= p.h * 0.75f }.groupBy { it.col }
                .filterValues { ls -> ls.count { it.mainSize >= bodySize * 0.92f } * 2 > ls.size }
                .keys
            // Narrow columns found by gap detection that hold running text (e.g. side quotes)
            // are read, not skipped as figure text.
            val textCols = if (p.gutters.isEmpty()) emptySet() else
                p.lines.filter { it.col != COL_FULL }.groupBy { it.col }.filterValues { it.size >= 8 }.keys
            var prev: Line? = null
            for (l in p.lines) {
                val width = l.x1 - l.x0
                val text = l.text
                l.kind = when {
                    l.isTableRow -> "table"
                    caption.containsMatchIn(text) -> { l.captionStart = true; "caption" }
                    l.mainSize >= bodySize * 1.15f -> "heading"
                    l.boldShare > 0.6f && text.length < 90 &&
                        (numberedHeading.containsMatchIn(text) || text.length < 40) -> "heading"
                    l.mainSize < bodySize * 0.8f && width < p.w * 0.2f && l.col !in textCols -> "small"
                    // Footnotes, copyright and license boxes at the bottom of the page.
                    l.mainSize < bodySize * 0.92f && l.y0 > p.h * 0.75f && l.col in bodyCols -> "footnote"
                    else -> "body"
                }
                // Lines right below a caption line, same size and tight spacing, continue it.
                val pv = prev
                if (l.kind == "body" && pv != null && pv.kind == "caption" && pv.col == l.col &&
                    l.y0 - pv.y1 < 0.6f * l.size
                ) {
                    l.kind = "caption"
                }
                prev = l
            }
        }
        return bodySize
    }

    // ------------------------------------------------------------------ floats

    class FloatRegion(
        val page: Int, val x0: Float, val y0: Float, val x1: Float, val y1: Float,
        val kind: String, val label: String,
    )

    /**
     * Finds figures and tables from their captions. A float is the caption plus the
     * area above it (figures) or below it (tables, when table rows are there), up to
     * the nearest paragraph text in the same column. Lines inside get a floatId.
     */
    private fun detectFloats(pages: List<PageResult>, bodySize: Float): List<FloatRegion> {
        val out = ArrayList<FloatRegion>()
        for (p in pages) {
            val lines = p.lines
            if (lines.isEmpty()) continue
            val body = lines.filter { it.kind == "body" }
            val tx0 = body.minOfOrNull { it.x0 } ?: lines.minOf { it.x0 }
            val tx1 = body.maxOfOrNull { it.x1 } ?: lines.maxOf { it.x1 }
            val mid = p.w / 2f
            val twoCol = lines.any { it.col != COL_FULL }
            val bounds = if (p.gutters.isNotEmpty()) listOf(tx0) + p.gutters + listOf(tx1) else listOf(tx0, mid, tx1)
            fun colRange(col: Int): Pair<Float, Float> =
                if (col >= 1 && col < bounds.size) bounds[col - 1] to bounds[col] else tx0 to tx1
            fun isProse(l: Line): Boolean {
                if (l.words.size < 6) return false
                val t = l.text
                return t.count { it.isLetter() } >= 0.6f * t.count { !it.isWhitespace() }
            }
            fun isParagraph(l: Line): Boolean {
                if (l.kind != "body" || l.isTableRow || l.monoShare > 0.5f || !isProse(l)) return false
                if (abs(l.mainSize - bodySize) > bodySize * 0.12f) return false
                val (a, b) = colRange(if (twoCol) l.col else COL_FULL)
                return (l.x1 - l.x0) > 0.6f * (b - a)
            }

            var i = 0
            while (i < lines.size) {
                val cap = lines[i]
                if (cap.kind != "caption" || !cap.captionStart) { i++; continue }
                var j = i
                while (j + 1 < lines.size && lines[j + 1].kind == "caption" && !lines[j + 1].captionStart) j++
                val block = lines.subList(i, j + 1)
                val by0 = block.minOf { it.y0 }
                val by1 = block.maxOf { it.y1 }
                val col = if (block.any { it.col == COL_FULL }) COL_FULL else cap.col
                val (ra, rb) = colRange(col)
                val rx0 = ra - p.w * 0.01f
                val rx1 = rb + p.w * 0.01f
                fun overlaps(l: Line) = l.x1 > rx0 + 2f && l.x0 < rx1 - 2f
                fun isBoundary(l: Line) = overlaps(l) && l !in block &&
                    (isParagraph(l) || l.kind == "caption")

                val upBound = lines.filter { isBoundary(it) && it.y1 <= by0 + 1f }.maxOfOrNull { it.y1 } ?: (p.h * 0.06f)
                val downBound = lines.filter { isBoundary(it) && it.y0 >= by1 - 1f }.minOfOrNull { it.y0 } ?: (p.h * 0.94f)
                fun tableRowsBetween(a: Float, b: Float) =
                    lines.count { it.isTableRow && overlaps(it) && it.y0 >= a && it.y1 <= b }

                val isTable = Regex("^(table|tab\\.)", RegexOption.IGNORE_CASE).containsMatchIn(cap.text)
                val minArea = 3f * bodySize
                val dir = if (isTable) {
                    when {
                        tableRowsBetween(by1, downBound) > 0 -> 1
                        tableRowsBetween(upBound, by0) > 0 -> -1
                        downBound - by1 > minArea -> 1
                        by0 - upBound > minArea -> -1
                        else -> 0
                    }
                } else {
                    when {
                        by0 - upBound > minArea -> -1
                        downBound - by1 > minArea -> 1
                        else -> 0
                    }
                }
                var fy0 = if (dir < 0) upBound + 1f else by0
                var fy1 = if (dir > 0) downBound - 1f else by1
                var fx0 = rx0
                var fx1 = rx1

                val id = out.size
                for (l in lines) {
                    if (l.floatId >= 0) continue
                    val cy = (l.y0 + l.y1) / 2f
                    val inside = l in block || (cy in fy0..fy1 && overlaps(l) && !isParagraph(l))
                    if (inside) {
                        l.floatId = id
                        fx0 = min(fx0, l.x0); fx1 = max(fx1, l.x1)
                        fy0 = min(fy0, l.y0); fy1 = max(fy1, l.y1)
                    }
                }
                // Small notes right under the float (e.g. "† Fine-tuned on ...") belong to it.
                var grew = true
                while (grew) {
                    grew = false
                    for (l in lines) {
                        if (l.floatId < 0 && overlaps(l) && l.mainSize < bodySize * 0.92f &&
                            l.y0 >= fy1 - 1f && l.y0 - fy1 < 1.2f * bodySize
                        ) {
                            l.floatId = id
                            fx0 = min(fx0, l.x0); fx1 = max(fx1, l.x1); fy1 = max(fy1, l.y1)
                            grew = true
                        }
                    }
                }
                val label = block.joinToString(" ") { it.text }.let { if (it.length > 140) it.take(137) + "..." else it }
                out.add(FloatRegion(p.index, fx0, fy0, fx1, fy1, if (isTable) "table" else "figure", label))
                i = j + 1
            }
        }
        return out
    }

    // ------------------------------------------------------------------ output
    private fun r4(v: Float): Double = (v * 10000f).roundToInt() / 10000.0

    private fun toJson(pages: List<PageResult>, bodySize: Float, floats: List<FloatRegion>): String {
        val pagesJson = JSONArray()
        val linesJson = JSONArray()
        for (p in pages) {
            pagesJson.put(JSONArray().put(r4(p.w)).put(r4(p.h)))
            for (l in p.lines) {
                // Word texts and their normalized [x0, x1] pairs, left to right.
                val ws = JSONArray()
                val wx = JSONArray()
                for (w in l.words.sortedBy { it.x0 }) {
                    ws.put(w.text)
                    wx.put(r4((w.x0 / p.w).coerceIn(0f, 1f))).put(r4((w.x1 / p.w).coerceIn(0f, 1f)))
                }
                linesJson.put(
                    JSONObject()
                        .put("p", p.index)
                        .put("x0", r4((l.x0 / p.w).coerceIn(0f, 1f)))
                        .put("y0", r4((l.y0 / p.h).coerceIn(0f, 1f)))
                        .put("x1", r4((l.x1 / p.w).coerceIn(0f, 1f)))
                        .put("y1", r4((l.y1 / p.h).coerceIn(0f, 1f)))
                        .put("c", l.col)
                        .put("s", r4(l.mainSize))
                        .put("f", l.floatId)
                        .put("k", l.kind)
                        .put("t", l.words.sortedBy { it.x0 }.joinToString(" ") { it.text })
                        .put("ws", ws)
                        .put("wx", wx)
                )
            }
        }
        val floatsJson = JSONArray()
        for (fl in floats) {
            val p = pages[fl.page]
            floatsJson.put(
                JSONObject()
                    .put("p", fl.page)
                    .put("x0", r4((fl.x0 / p.w).coerceIn(0f, 1f)))
                    .put("y0", r4((fl.y0 / p.h).coerceIn(0f, 1f)))
                    .put("x1", r4((fl.x1 / p.w).coerceIn(0f, 1f)))
                    .put("y1", r4((fl.y1 / p.h).coerceIn(0f, 1f)))
                    .put("k", fl.kind)
                    .put("t", fl.label)
            )
        }
        return JSONObject()
            .put("version", VERSION)
            .put("floats", floatsJson)
            .put("body_size", r4(bodySize))
            .put("pages", pagesJson)
            .put("lines", linesJson)
            .toString()
    }
}
