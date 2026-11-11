package com.paperreader.pdf

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Log
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Godot singleton "PdfReader".
 *
 * Godot polls this plugin instead of receiving signals, so nothing is
 * called back across threads. Results are passed as JSON strings.
 */
class PdfReaderPlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "PdfReader"
        private const val REQ_PICK = 4711
    }

    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val renderLock = Any()

    private var renderer: PdfRenderer? = null
    private var rendererFd: ParcelFileDescriptor? = null
    private var currentFile: File? = null

    // "" = idle, "pending", "cancelled", "error:<msg>", "ok:<path>"
    @Volatile private var pickState = ""

    // "idle", "running", "done", "error"
    @Volatile private var analysisState = "idle"
    @Volatile private var analysisProgress = 0f
    @Volatile private var analysisResult = ""
    @Volatile private var analysisGeneration = 0
    @Volatile private var lastError = ""

    override fun getPluginName() = "PdfReader"

    private var storageRoot: File? = null

    /**
     * Documents/HighReader on shared storage (visible in the Files app), or the
     * app's private folder if shared storage can't be written.
     */
    private fun root(): File {
        storageRoot?.let { return it }
        val shared = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS), "HighReader")
        val chosen = try {
            shared.mkdirs()
            val probe = File(shared, ".probe")
            probe.writeText("ok")
            probe.delete()
            shared
        } catch (e: Exception) {
            Log.w(TAG, "shared storage not writable, using private storage", e)
            activity!!.filesDir
        }
        storageRoot = chosen
        return chosen
    }

    private fun libraryDir(): File = File(root(), "papers").apply { mkdirs() }
    private fun analysisDir(): File = File(root(), "cache").apply { mkdirs() }

    /** Folder holding papers, cache and reading progress. */
    @UsedByGodot
    fun getStorageDir(): String = root().absolutePath

    // ---------------------------------------------------------------- picking

    @UsedByGodot
    fun pickPdf() {
        val act = activity ?: return
        pickState = "pending"
        act.runOnUiThread {
            try {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/pdf"
                }
                act.startActivityForResult(intent, REQ_PICK)
            } catch (e: Exception) {
                pickState = "error:${e.message}"
            }
        }
    }

    /** Returns the pick state once; resets to "" after a final state is read. */
    @UsedByGodot
    fun pollPick(): String {
        val s = pickState
        if (s != "pending") pickState = ""
        return s
    }

    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onMainActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pickState = "cancelled"
            return
        }
        Thread {
            pickState = try {
                "ok:" + importUri(uri).absolutePath
            } catch (e: Exception) {
                Log.e(TAG, "import failed", e)
                "error:${e.message}"
            }
        }.start()
    }

    private fun importUri(uri: Uri): File {
        val act = activity!!
        var name = "document.pdf"
        act.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0)?.let { name = it }
        }
        name = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        if (!name.lowercase().endsWith(".pdf")) name += ".pdf"
        // A file left by an earlier install can't be overwritten; pick a free name.
        var target = File(libraryDir(), name)
        var n = 2
        while (target.exists() && !target.canWrite()) {
            target = File(libraryDir(), name.removeSuffix(".pdf") + " ($n).pdf")
            n++
        }
        act.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Cannot read file" }
            target.outputStream().use { input.copyTo(it) }
        }
        return target
    }

    @UsedByGodot
    fun listLibrary(): String {
        // PDFs dropped into the private "inbox" folder (e.g. over adb) join the library.
        File(activity!!.filesDir, "inbox").listFiles { f -> f.name.lowercase().endsWith(".pdf") }?.forEach { f ->
            runCatching {
                val target = File(libraryDir(), f.name)
                f.copyTo(target, overwrite = true)
                f.delete()
            }.onFailure { Log.w(TAG, "inbox import failed", it) }
        }
        val arr = JSONArray()
        libraryDir().listFiles { f -> f.isFile && f.canRead() && f.name.lowercase().endsWith(".pdf") }
            ?.sortedByDescending { it.lastModified() }
            ?.forEach { f ->
                arr.put(JSONObject().put("name", f.name).put("path", f.absolutePath).put("size", f.length()))
            }
        return arr.toString()
    }

    @UsedByGodot
    fun deleteFromLibrary(path: String): Boolean {
        val f = File(path)
        if (f.parentFile?.canonicalPath != libraryDir().canonicalPath) return false
        analysisDir().listFiles { c -> c.name.startsWith(f.name + "_") }?.forEach { it.delete() }
        return f.delete()
    }

    // -------------------------------------------------------------- rendering

    /** Opens a PDF. Returns {"pages":[[w,h],...]} in PDF points, or "" on failure. */
    @UsedByGodot
    fun openPdf(path: String): String {
        closePdf()
        return try {
            val file = File(path)
            val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val r = PdfRenderer(fd)
            val pages = JSONArray()
            for (i in 0 until r.pageCount) {
                r.openPage(i).use { p -> pages.put(JSONArray().put(p.width).put(p.height)) }
            }
            synchronized(renderLock) {
                rendererFd = fd
                renderer = r
            }
            currentFile = file
            JSONObject().put("pages", pages).put("name", file.name).toString()
        } catch (e: Exception) {
            Log.e(TAG, "openPdf failed", e)
            lastError = e.message ?: e.toString()
            ""
        }
    }

    /** Renders a page to raw RGBA8 bytes, [width] pixels wide. Height = size / (4 * width). */
    @UsedByGodot
    fun renderPage(index: Int, width: Int): ByteArray {
        synchronized(renderLock) {
            val r = renderer ?: return ByteArray(0)
            if (index < 0 || index >= r.pageCount || width <= 0) return ByteArray(0)
            return try {
                r.openPage(index).use { page ->
                    val h = Math.round(width.toFloat() * page.height / page.width).coerceAtLeast(1)
                    val bmp = Bitmap.createBitmap(width, h, Bitmap.Config.ARGB_8888)
                    bmp.eraseColor(Color.WHITE)
                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val buf = ByteBuffer.allocate(width * h * 4)
                    bmp.copyPixelsToBuffer(buf)
                    bmp.recycle()
                    buf.array()
                }
            } catch (e: Exception) {
                Log.e(TAG, "renderPage failed", e)
                lastError = e.message ?: e.toString()
                ByteArray(0)
            }
        }
    }

    @UsedByGodot
    fun closePdf() {
        analysisGeneration++
        synchronized(renderLock) {
            try { renderer?.close() } catch (_: Exception) {}
            try { rendererFd?.close() } catch (_: Exception) {}
            renderer = null
            rendererFd = null
        }
        currentFile = null
        analysisState = "idle"
        analysisResult = ""
    }

    // --------------------------------------------------------------- analysis

    /** Starts text-line analysis of the open PDF in the background (cached per file). */
    @UsedByGodot
    fun startAnalysis(): Boolean {
        val file = currentFile ?: return false
        val ctx = activity?.applicationContext ?: return false
        val gen = ++analysisGeneration
        analysisState = "running"
        analysisProgress = 0f
        analysisResult = ""
        val cache = File(analysisDir(), "${file.name}_${file.length()}_v${PaperAnalyzer.VERSION}.json")
        analysisExecutor.execute {
            try {
                val cached = if (cache.isFile) runCatching { cache.readText() }.getOrNull() else null
                val json = if (cached != null) {
                    cached
                } else {
                    PDFBoxResourceLoader.init(ctx)
                    val result = PaperAnalyzer.analyze(file) { p ->
                        if (gen == analysisGeneration) analysisProgress = p
                    }
                    // Drop caches from older analyzer versions of this file.
                    analysisDir().listFiles { f -> f.name.startsWith(file.name + "_") && f.name != cache.name }
                        ?.forEach { it.delete() }
                    runCatching { cache.writeText(result) }.onFailure { Log.w(TAG, "cache not saved", it) }
                    result
                }
                if (gen == analysisGeneration) {
                    analysisResult = json
                    analysisProgress = 1f
                    analysisState = "done"
                }
            } catch (t: Throwable) {
                Log.e(TAG, "analysis failed", t)
                if (gen == analysisGeneration) {
                    lastError = t.message ?: t.toString()
                    analysisState = "error"
                }
            }
        }
        return true
    }

    @UsedByGodot fun getAnalysisState(): String = analysisState
    @UsedByGodot fun getAnalysisProgress(): Float = analysisProgress
    @UsedByGodot fun getAnalysisResult(): String = analysisResult
    @UsedByGodot fun getLastError(): String = lastError
}
