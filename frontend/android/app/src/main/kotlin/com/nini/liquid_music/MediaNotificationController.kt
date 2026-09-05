package com.nini.liquid_music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media.MediaBrowserServiceCompat
import android.support.v4.media.session.MediaSessionCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat as MediaNotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

/**
 * 自定义媒体通知控制器（Part 2）
 *
 * 用与 audio_service 相同的通知 ID（1124）+ 相同通知渠道，以自定义
 * RemoteViews 通知覆盖其默认 MediaStyle 通知：
 * - 封面（网络加载，内存缓存）
 * - 歌名 / 歌手 / 当前歌词行（逐行更新）
 * - 收藏 ♥ 按钮（回传 Flutter 走现有 like + 本地收藏逻辑）
 * - 上一首 / 播放暂停 / 下一首（回传 Flutter）
 * - 进度条（随 Dart 推送更新）
 *
 * 同时通过反射拿 audio_service 的 MediaSession token 挂 MediaStyle，
 * 保证 Android 13+ 的系统媒体卡片 / 锁屏控制 / 进度拖动不受影响。
 */
object MediaNotificationController {
    const val CHANNEL_ID = "com.nini.liquid_music.channel.audio"

    // 与 com.ryanheise.audioservice.AudioService.NOTIFICATION_ID 一致
    private const val NOTIFICATION_ID = 1124

    const val ACTION_PREV = "com.nini.liquid_music.notification.PREV"
    const val ACTION_TOGGLE = "com.nini.liquid_music.notification.TOGGLE"
    const val ACTION_NEXT = "com.nini.liquid_music.notification.NEXT"
    const val ACTION_FAVORITE = "com.nini.liquid_music.notification.FAVORITE"

    /** MainActivity 注入，用于原生按钮事件回传 Flutter */
    @Volatile
    var flutterChannel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var repostRunnable: Runnable? = null
    private var latestData: Map<*, *>? = null

    // 封面缓存（单曲级别）
    @Volatile private var artUrl: String? = null
    @Volatile private var artBitmap: Bitmap? = null
    @Volatile private var artFetching = false

    // MediaSession token 缓存（反射自 audio_service 的 AudioService.instance）
    @Volatile private var sessionToken: MediaSessionCompat.Token? = null

    fun update(context: Context, data: Map<*, *>?) {
        if (data == null) return
        latestData = data
        val ctx = context.applicationContext
        val cover = data["cover"] as? String
        if (!cover.isNullOrEmpty() && cover != artUrl) {
            fetchArtAsync(ctx, cover)
        }
        schedulePost(ctx)
    }

    fun hide(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    /** 通知栏按钮点击 → Flutter */
    fun dispatchAction(action: String) {
        val ch = flutterChannel ?: return
        mainHandler.post { ch.invokeMethod("onAction", action) }
    }

    /** 250ms 防抖：确保晚于 audio_service 的通知重发，实现稳定覆盖 */
    private fun schedulePost(ctx: Context) {
        repostRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable {
            repostRunnable = null
            post(ctx)
        }
        repostRunnable = r
        mainHandler.postDelayed(r, 250)
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(
                Context.NOTIFICATION_SERVICE
            ) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "音乐播放", NotificationManager.IMPORTANCE_LOW
                    )
                )
            }
        }
    }

    /** 反射获取 audio_service 持有的 MediaSession token（拿不到则降级为普通通知） */
    private fun obtainSessionToken(): MediaSessionCompat.Token? {
        sessionToken?.let { return it }
        return try {
            val clazz = Class.forName("com.ryanheise.audioservice.AudioService")
            val field = clazz.getDeclaredField("instance").apply { isAccessible = true }
            val service = field.get(null) as? MediaBrowserServiceCompat
            val token = service?.sessionToken
            sessionToken = token
            token
        } catch (e: Exception) {
            null
        }
    }

    private fun fetchArtAsync(context: Context, url: String) {
        if (artFetching) return
        artFetching = true
        Thread {
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                val bmp = BitmapFactory.decodeStream(conn.inputStream)
                conn.disconnect()
                if (bmp != null) {
                    artBitmap = bmp
                    artUrl = url
                    schedulePost(context)
                }
            } catch (e: Exception) {
                // 封面加载失败静默处理，通知继续显示占位图
            } finally {
                artFetching = false
            }
        }.apply { isDaemon = true }.start()
    }

    private fun post(context: Context) {
        val data = latestData ?: return
        val title = data["title"] as? String ?: ""
        val artist = data["artist"] as? String ?: ""
        val isPlaying = data["isPlaying"] as? Boolean ?: false
        val isFavorite = data["isFavorite"] as? Boolean ?: false

        createChannel(context)

        // 点击通知主体回到 App
        val launchIntent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentPi = launchIntent?.let {
            it.addFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
            PendingIntent.getActivity(
                context, 1001, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        // 标准媒体通知（非 RemoteViews）：避免大框套小框，且 MediaStyle
        // 挂 MediaSession 保证 Android 13+ 系统媒体卡片/锁屏/上岛正常
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(title)
            .setContentText(artist.ifEmpty { " " })
            .setOngoing(isPlaying)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
        artBitmap?.let { builder.setLargeIcon(it) }
        contentPi?.let { builder.setContentIntent(it) }

        // 控制按钮：上一首 / 播放暂停 / 下一首（自定义通知覆盖了 audio_service
        // 的默认通知，控制按钮必须由我们自己 addAction，系统不会自动补）
        builder.addAction(
            R.drawable.ic_notif_prev, "上一首", actionPi(context, ACTION_PREV)
        )
        builder.addAction(
            if (isPlaying) R.drawable.ic_notif_pause else R.drawable.ic_notif_play,
            if (isPlaying) "暂停" else "播放",
            actionPi(context, ACTION_TOGGLE)
        )
        builder.addAction(
            R.drawable.ic_notif_next, "下一首", actionPi(context, ACTION_NEXT)
        )
        // 附加"收藏"按钮（点爱心 → 回传 Flutter 走本地 + 网易云收藏逻辑）
        val favIcon =
            if (isFavorite) R.drawable.ic_notif_fav_filled else R.drawable.ic_notif_fav
        builder.addAction(favIcon, "收藏", actionPi(context, ACTION_FAVORITE))

        // 挂 MediaSession：Android 13+ 系统媒体卡片 / 锁屏 / 上岛依赖；
        // 折叠状态下展示"播放/暂停"按钮（index 1），展开显示全部 4 个
        obtainSessionToken()?.let { token ->
            builder.setStyle(
                MediaNotificationCompat.MediaStyle()
                    .setMediaSession(token)
                    .setShowActionsInCompactView(1)
            )
        }
        try {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            // Android 13+ 未授予通知权限时静默忽略
        }
    }

    /** 通知按钮 PendingIntent（Broadcast → MediaNotificationReceiver → Flutter） */
    private fun actionPi(context: Context, action: String): PendingIntent {
        val intent = Intent(context, MediaNotificationReceiver::class.java).setAction(action)
        return PendingIntent.getBroadcast(
            context, action.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
