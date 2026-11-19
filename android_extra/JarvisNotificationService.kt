package com.kaido.jarvis_app

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.MethodChannel

// Set by MainActivity so the service can talk to the Dart side.
object NotificationBridge {
    @Volatile
    var channel: MethodChannel? = null
}

class JarvisNotificationService : NotificationListenerService() {

    companion object {
        @Volatile
        var instance: JarvisNotificationService? = null

        private val skipPackages = setOf(
            "android",
            "com.android.systemui",
            "com.miui.securitycenter",
            "com.miui.powerkeeper",
            "com.xiaomi.xmsf",
            "com.google.android.gms",
            "com.android.providers.downloads"
        )
        private val skipCategories = setOf(
            Notification.CATEGORY_TRANSPORT,
            Notification.CATEGORY_PROGRESS,
            Notification.CATEGORY_SERVICE,
            Notification.CATEGORY_SYSTEM,
            Notification.CATEGORY_STATUS
        )
    }

    private class Entry(
        val remoteInputs: Array<RemoteInput>?,
        val replyIntent: PendingIntent?,
        val contentIntent: PendingIntent?
    )

    private val entries = LinkedHashMap<String, Entry>()
    private var lastSignature = ""
    private var lastSignatureTime = 0L

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
    }

    override fun onListenerDisconnected() {
        instance = null
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        try {
            handle(sbn)
        } catch (e: Exception) {
        }
    }

    private fun handle(sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: return
        if (pkg == packageName || skipPackages.contains(pkg)) return
        val n = sbn.notification ?: return
        if (sbn.isOngoing) return
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val cat = n.category
        if (cat != null && skipCategories.contains(cat)) return

        val ex = n.extras ?: return
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isBlank() && text.isBlank()) return

        // ignore the same notification repeated within a few seconds
        val sig = pkg + "|" + title + "|" + text
        val now = System.currentTimeMillis()
        if (sig == lastSignature && now - lastSignatureTime < 10000) return
        lastSignature = sig
        lastSignatureTime = now

        var replyIntent: PendingIntent? = null
        var inputs: Array<RemoteInput>? = null
        val actions = n.actions
        if (actions != null) {
            for (a in actions) {
                val ri = a.remoteInputs
                if (ri != null && ri.isNotEmpty() && a.actionIntent != null) {
                    replyIntent = a.actionIntent
                    inputs = ri
                    break
                }
            }
        }

        entries[sbn.key] = Entry(inputs, replyIntent, n.contentIntent)
        while (entries.size > 30) {
            val first = entries.keys.iterator().next()
            entries.remove(first)
        }

        val label = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) {
            pkg
        }

        val data = hashMapOf<String, Any>(
            "key" to sbn.key,
            "app" to label,
            "package" to pkg,
            "title" to title,
            "text" to text.take(300),
            "canReply" to (replyIntent != null)
        )
        Handler(Looper.getMainLooper()).post {
            NotificationBridge.channel?.invokeMethod("notification", data)
        }
    }

    fun reply(key: String, text: String): Boolean {
        val e = entries[key] ?: return false
        val inputs = e.remoteInputs ?: return false
        val pi = e.replyIntent ?: return false
        return try {
            val intent = Intent()
            val bundle = Bundle()
            for (r in inputs) {
                bundle.putCharSequence(r.resultKey, text)
            }
            RemoteInput.addResultsToIntent(inputs, intent, bundle)
            pi.send(this, 0, intent)
            true
        } catch (ex: Exception) {
            false
        }
    }

    fun open(key: String): Boolean {
        val pi = entries[key]?.contentIntent ?: return false
        return try {
            pi.send()
            true
        } catch (ex: Exception) {
            false
        }
    }
}
