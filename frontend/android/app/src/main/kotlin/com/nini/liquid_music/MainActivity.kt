package com.nini.liquid_music

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 必须继承 AudioServiceActivity：为其提供后台共享 FlutterEngine，否则 AudioService.init 抛 PlatformException（白屏） */
class MainActivity : AudioServiceActivity() {
    companion object {
        private const val CHANNEL = "liquid_music/media_notification"
        private const val REQUEST_NOTIFICATIONS = 100
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+ 运行时申请通知权限（媒体通知必需，首次启动弹一次）
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATIONS
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        )
        MediaNotificationController.flutterChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    MediaNotificationController.update(
                        applicationContext, call.arguments as? Map<*, *>
                    )
                    result.success(null)
                }
                "hide" -> {
                    MediaNotificationController.hide(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
