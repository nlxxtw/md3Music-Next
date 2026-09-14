package com.md3music.md3music

import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.Log
import com.ryanheise.just_audio.AudioPlayer

/**
 * 媒体通知栏歌词：在 MediaStyle 的 contentText（歌名下方）显示当前行，
 * 已唱白色 / 未唱灰色，按字级时间戳从左往右推进（类跑马灯）。
 */
object NotificationLyricStore {
    private const val TAG = "NotifLyric"
    private const val COLOR_SUNG = Color.WHITE
    private const val COLOR_UNSUNG = 0xFF9E9E9E.toInt()
    private const val MIN_REFRESH_MS = 280L

    @Volatile
    private var lineText: String = ""

    @Volatile
    private var words: List<WordTiming> = emptyList()

    @Volatile
    private var basePosMs: Long = 0L

    @Volatile
    private var baseElapsedMs: Long = 0L

    @Volatile
    private var playing: Boolean = false

    @Volatile
    private var lineStartMs: Long = 0L

    @Volatile
    private var lineEndMs: Long = 0L

    private var lastRefreshAt = 0L
    private val handler = Handler(Looper.getMainLooper())
    private val tickRunnable = Runnable { onTick() }

    data class WordTiming(val text: String, val startMs: Long, val durationMs: Long)

    fun clear() {
        lineText = ""
        words = emptyList()
        handler.removeCallbacks(tickRunnable)
        requestRefresh(force = true)
    }

    /**
     * @param text 当前行全文
     * @param wordMaps Dart 下发的 [{t,s,d}, ...]；空则按行时长比例推进
     * @param positionMs 推送时的播放位置
     * @param isPlaying 是否在播
     * @param lineStartMs 行起始（无逐字时用于比例着色）
     * @param lineEndMs 行结束
     */
    fun updateLine(
        text: String,
        wordMaps: List<Map<*, *>>?,
        positionMs: Long,
        isPlaying: Boolean,
        lineStartMs: Long = 0L,
        lineEndMs: Long = 0L,
    ) {
        lineText = text.trim()
        this.lineStartMs = lineStartMs
        this.lineEndMs = if (lineEndMs > lineStartMs) lineEndMs else lineStartMs + 5000L
        playing = isPlaying
        basePosMs = positionMs
        baseElapsedMs = SystemClock.elapsedRealtime()

        val parsed = ArrayList<WordTiming>()
        if (wordMaps != null) {
            for (m in wordMaps) {
                val t = m["t"]?.toString() ?: continue
                if (t.isEmpty()) continue
                val s = (m["s"] as? Number)?.toLong() ?: 0L
                val d = (m["d"] as? Number)?.toLong() ?: 0L
                parsed.add(WordTiming(t, s, d.coerceAtLeast(1L)))
            }
        }
        words = parsed

        handler.removeCallbacks(tickRunnable)
        requestRefresh(force = true)
        if (playing && lineText.isNotEmpty()) {
            scheduleNextTick()
        }
    }

    fun onPlayingChanged(isPlaying: Boolean) {
        if (!isPlaying && playing) {
            basePosMs = estimatedPos()
        }
        playing = isPlaying
        baseElapsedMs = SystemClock.elapsedRealtime()
        handler.removeCallbacks(tickRunnable)
        requestRefresh(force = true)
        if (playing && lineText.isNotEmpty()) {
            scheduleNextTick()
        }
    }

    /** 供 MediaNotificationProvider 读取：有歌词返回着色 CharSequence，否则 null（回退歌手）。 */
    fun contentTextOrNull(): CharSequence? {
        val text = lineText
        if (text.isEmpty()) return null
        return buildKaraokeSpannable(text, estimatedPos())
    }

    private fun estimatedPos(): Long {
        if (!playing) return basePosMs
        return basePosMs + (SystemClock.elapsedRealtime() - baseElapsedMs)
    }

    private fun buildKaraokeSpannable(text: String, posMs: Long): CharSequence {
        val spannable = SpannableString(text)
        // 默认整行未唱灰
        spannable.setSpan(
            ForegroundColorSpan(COLOR_UNSUNG),
            0,
            text.length,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )

        val sungEnd: Int = when {
            words.isNotEmpty() -> sungCharIndexByWords(text, posMs)
            else -> sungCharIndexByLineRatio(text, posMs)
        }
        if (sungEnd > 0) {
            spannable.setSpan(
                ForegroundColorSpan(COLOR_SUNG),
                0,
                sungEnd.coerceAtMost(text.length),
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
        return spannable
    }

    private fun sungCharIndexByWords(text: String, posMs: Long): Int {
        var idx = 0
        for (w in words) {
            val end = w.startMs + w.durationMs
            when {
                posMs >= end -> idx += w.text.length
                posMs <= w.startMs -> return idx
                else -> {
                    // 字内比例
                    val frac = ((posMs - w.startMs).toDouble() / w.durationMs).coerceIn(0.0, 1.0)
                    val partial = (w.text.length * frac).toInt()
                    return (idx + partial).coerceAtMost(text.length)
                }
            }
            if (idx >= text.length) return text.length
        }
        return idx.coerceAtMost(text.length)
    }

    private fun sungCharIndexByLineRatio(text: String, posMs: Long): Int {
        val start = lineStartMs
        val end = lineEndMs
        if (end <= start || text.isEmpty()) return 0
        val frac = ((posMs - start).toDouble() / (end - start)).coerceIn(0.0, 1.0)
        return (text.length * frac).toInt().coerceIn(0, text.length)
    }

    private fun onTick() {
        if (!playing || lineText.isEmpty()) return
        requestRefresh(force = false)
        scheduleNextTick()
    }

    private fun scheduleNextTick() {
        handler.removeCallbacks(tickRunnable)
        if (!playing || lineText.isEmpty()) return
        val delay = if (words.isNotEmpty()) {
            // 对齐下一字边界，夹在 180~450ms，兼顾流畅与通知刷新压力
            val pos = estimatedPos()
            var next = 320L
            for (w in words) {
                val edge = w.startMs
                if (edge > pos + 20) {
                    next = (edge - pos).coerceIn(180L, 450L)
                    break
                }
                val end = w.startMs + w.durationMs
                if (end > pos + 20) {
                    next = (end - pos).coerceIn(180L, 450L)
                    break
                }
            }
            next
        } else {
            320L
        }
        handler.postDelayed(tickRunnable, delay)
    }

    private fun requestRefresh(force: Boolean) {
        val now = SystemClock.elapsedRealtime()
        if (!force && now - lastRefreshAt < MIN_REFRESH_MS) return
        lastRefreshAt = now
        handler.post {
            try {
                AudioPlayer.refreshActiveNotification()
            } catch (e: Exception) {
                Log.w(TAG, "refresh failed: ${e.message}")
            }
        }
    }
}
