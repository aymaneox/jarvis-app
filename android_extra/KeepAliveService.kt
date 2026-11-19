package com.kaido.jarvis_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager

class KeepAliveService : Service() {

    companion object {
        @Volatile
        var instance: KeepAliveService? = null

        // updated by the Dart side every few seconds; if it stops, the app was killed
        @Volatile
        var lastBeat: Long = 0L
        private const val CHANNEL_ID = "jarvis_listening"
        private const val NOTIF_ID = 4242
    }

    private val handler = Handler(Looper.getMainLooper())
    private var lastRelaunch = 0L

    private val checker = object : Runnable {
        override fun run() {
            try {
                val now = System.currentTimeMillis()
                if (lastBeat > 0 && now - lastBeat > 45000 && now - lastRelaunch > 90000) {
                    lastRelaunch = now
                    val i = packageManager.getLaunchIntentForPackage(packageName)
                    if (i != null) {
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        i.putExtra("jarvis_bg", true)
                        startActivity(i)
                    }
                }
            } catch (e: Exception) {
            }
            handler.postDelayed(this, 10000)
        }
    }

    private var orb: View? = null
    private var orbDrawable: GradientDrawable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startAsForeground()
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        showOrb()
        lastBeat = System.currentTimeMillis()
        handler.removeCallbacks(checker)
        handler.postDelayed(checker, 10000)
        return START_STICKY
    }

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Jarvis", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Jarvis is listening")
            .setContentText("Say \"Jarvis\" to talk")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 30) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun showOrb() {
        if (orb != null) return
        if (!Settings.canDrawOverlays(this)) return
        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val density = resources.displayMetrics.density
            val size = (26 * density).toInt()

            val drawable = GradientDrawable()
            drawable.setShape(GradientDrawable.OVAL)
            drawable.setColor(Color.parseColor("#00DCFF"))
            drawable.setStroke(2, Color.WHITE)

            val v = View(this)
            v.background = drawable
            v.alpha = 0.9f

            val type = if (Build.VERSION.SDK_INT >= 26) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            val lp = WindowManager.LayoutParams(
                size, size, type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            )
            lp.gravity = Gravity.TOP or Gravity.END
            lp.x = (8 * density).toInt()
            lp.y = (60 * density).toInt()

            wm.addView(v, lp)
            orb = v
            orbDrawable = drawable
        } catch (e: Exception) {
            // overlay not allowed: Jarvis still works without the orb
        }
    }

    fun setOrb(state: String) {
        val color = when (state) {
            "listening" -> "#3DFF7A"
            "thinking" -> "#FFB020"
            "speaking" -> "#B070FF"
            else -> "#00DCFF"
        }
        orbDrawable?.setColor(Color.parseColor(color))
        orb?.invalidate()
    }

    override fun onDestroy() {
        handler.removeCallbacks(checker)
        try {
            orb?.let {
                val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                wm.removeView(it)
            }
        } catch (e: Exception) {
        }
        orb = null
        orbDrawable = null
        instance = null
        super.onDestroy()
    }
}
