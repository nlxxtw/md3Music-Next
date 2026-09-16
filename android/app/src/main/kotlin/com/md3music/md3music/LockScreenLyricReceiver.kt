package com.md3music.md3music

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// 锁屏歌词启动广播：仅在仍处于锁屏（Keyguard 锁定）时拉起全屏歌词。
/// 开屏解锁瞬间不要再 startActivity：与原子/SystemUI 同时醒来会卡死整机。
class LockScreenLyricReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_SCREEN_OFF && action != Intent.ACTION_SCREEN_ON) return
        android.util.Log.i(
            "LockScreenLyric",
            "$action received, isNowPlaying=${AudioPlaybackService.isNowPlaying}",
        )
        if (!AudioPlaybackService.isNowPlaying) return

        val enabled = try {
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.settings_lock_screen_lyric_enabled", false)
        } catch (_: Exception) {
            false
        }
        android.util.Log.i("LockScreenLyric", "$action: lockScreenLyricEnabled=$enabled")
        if (!enabled) return

        val kg = context.getSystemService(KeyguardManager::class.java)
        val locked = try {
            kg?.isKeyguardLocked == true
        } catch (_: Exception) {
            action == Intent.ACTION_SCREEN_OFF
        }

        if (action == Intent.ACTION_SCREEN_ON && !locked) {
            // 已解锁（快速开锁竞态）：关掉残留覆盖层，绝不重新拉起
            android.util.Log.i("LockScreenLyric", "SCREEN_ON unlocked → dismiss only")
            LockScreenLyricActivity.dismiss()
            return
        }

        if (locked || action == Intent.ACTION_SCREEN_OFF) {
            LockScreenLyricActivity.start(context)
        }
    }
}
