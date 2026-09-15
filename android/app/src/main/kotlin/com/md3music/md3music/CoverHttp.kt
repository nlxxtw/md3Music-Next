package com.md3music.md3music

import java.net.HttpURLConnection
import java.net.URL

/**
 * 在线封面 / CDN 拉取：补 https、按域名加 UA + Referer。
 * 网易 `music.126.net` 无 Referer 时常 403，导致锁屏/原子随身听/通知栏无封面，
 * 并在后台反复超时重试拖慢整机。
 */
object CoverHttp {
    private const val CHROME_UA =
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/120.0.0.0 Mobile Safari/537.36"
    private const val LUNA_UA =
        "com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; " +
            "ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)"

    /** http → https；`//host` → https。 */
    fun normalizeUrl(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        var u = raw.trim()
        if (u.startsWith("//")) u = "https:$u"
        if (u.startsWith("http://")) u = "https://" + u.substring(7)
        return u
    }

    fun open(rawUrl: String, connectMs: Int = 5000, readMs: Int = 10000): HttpURLConnection {
        val url = normalizeUrl(rawUrl) ?: rawUrl
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = connectMs
        conn.readTimeout = readMs
        conn.instanceFollowRedirects = true
        applyHeaders(conn, url)
        return conn
    }

    fun applyHeaders(conn: HttpURLConnection, url: String) {
        val host = try {
            URL(url).host.lowercase()
        } catch (_: Exception) {
            ""
        }
        when {
            host.contains("music.126.net") ||
                host.contains("163.com") ||
                host.contains("netease") -> {
                conn.setRequestProperty("User-Agent", CHROME_UA)
                conn.setRequestProperty("Referer", "https://music.163.com/")
            }
            host.contains("qqovo") -> {
                conn.setRequestProperty("User-Agent", CHROME_UA)
                conn.setRequestProperty("Referer", "https://music.qqovo.cn/")
            }
            host.contains("qq.com") ||
                host.contains("gtimg") ||
                host.contains("qqmusic") ||
                host.contains("tencentmusic") ||
                host.contains("aqqmusic") -> {
                conn.setRequestProperty("User-Agent", CHROME_UA)
                conn.setRequestProperty("Referer", "https://y.qq.com/")
            }
            host.contains("douyin") ||
                host.contains("byteimg") ||
                host.contains("bytevod") ||
                host.contains("qishui") ||
                host.contains("luna") ||
                host.contains("tos-cn") ||
                host.contains("snssdk") ||
                host.contains("pstatp") -> {
                conn.setRequestProperty("User-Agent", LUNA_UA)
                conn.setRequestProperty("Referer", "https://www.qishui.com/")
            }
            else -> {
                conn.setRequestProperty("User-Agent", CHROME_UA)
            }
        }
    }
}
