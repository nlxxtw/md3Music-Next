package com.md3music.md3music

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider

/**
 * 媒体通知：歌名下方 contentText 优先显示当前整行歌词（无逐字动画，避免
 * 高频 refresh 卡死 SystemUI/原子），无歌词时回退为歌手名。
 */
@OptIn(UnstableApi::class)
class LyricMediaNotificationProvider(
    context: Context,
) : DefaultMediaNotificationProvider(context) {

    override fun getNotificationContentText(metadata: MediaMetadata): CharSequence? {
        val lyric = NotificationLyricStore.contentTextOrNull()
        if (lyric != null && lyric.isNotEmpty()) {
            return lyric
        }
        return super.getNotificationContentText(metadata)
    }
}
