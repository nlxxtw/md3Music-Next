package com.md3music.md3music

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.ryanheise.just_audio.AudioPlayer

/**
 * 媒体通知栏歌词：在 MediaStyle 的 contentText（歌名下方）显示**当前整行**。
 *
 * 刻意不做逐字卡拉 OK / 定时 tick：过密 `refreshNotification` 会拖死
 * SystemUI / vivo 原子组件整机。仅在换行（或清空）时节流刷新一次。
 */
object NotificationLyricStore {
    private const val TAG = "NotifLyric"
    // 换行刷新节流：避免连跳/重复推送打爆通知
    private const val MIN_REFRESH_MS = 1000L

    @Volatile
    private var lineText: String = ""

    private var lastRefreshAt = 0L
    private val handler = Handler(Looper.getMainLooper())

    fun clear() {
        if (lineText.isEmpty()) return
        lineText = ""
        requestRefresh(force = true)
    }

    /**
     * @param text 当前行全文（忽略逐字时间戳，仅作换行更新）
     * @param wordMaps 保留参数兼容 Dart 通道，已不再用于通知着色
     */
    fun updateLine(
        text: String,
        wordMaps: List<Map<*, *>>?,
        positionMs: Long,
        isPlaying: Boolean,
        lineStartMs: Long = 0L,
        lineEndMs: Long = 0L,
    ) {
        val next = text.trim()
        if (next == lineText) return
        lineText = next
        // 换行才刷；走节流，禁止无脑 force 狂刷
        requestRefresh(force = false)
    }

    fun onPlayingChanged(isPlaying: Boolean) {
        // 播放状态变化不重绘歌词通知，避免暂停/恢复时再锤 SystemUI
    }

    /** 供 MediaNotificationProvider：有歌词返回纯文本，否则 null（回退歌手）。 */
    fun contentTextOrNull(): CharSequence? {
        val text = lineText
        return if (text.isEmpty()) null else text
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
