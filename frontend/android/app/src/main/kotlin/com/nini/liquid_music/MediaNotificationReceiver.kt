package com.nini.liquid_music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 自定义媒体通知按钮点击 → 回传 Flutter（经 MediaNotificationController） */
class MediaNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = when (intent.action) {
            MediaNotificationController.ACTION_PREV -> "prev"
            MediaNotificationController.ACTION_TOGGLE -> "toggle"
            MediaNotificationController.ACTION_NEXT -> "next"
            MediaNotificationController.ACTION_FAVORITE -> "favorite"
            else -> return
        }
        MediaNotificationController.dispatchAction(action)
    }
}
