package com.kaido.jarvis_app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class JarvisAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: JarvisAccessibilityService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // ---------- scroll ----------

    fun scroll(direction: String): Boolean {
        val dm = resources.displayMetrics
        val w = dm.widthPixels.toFloat()
        val h = dm.heightPixels.toFloat()
        val path = Path()
        when (direction.lowercase()) {
            // "down" = show content further down the page = finger moves up
            "down" -> {
                path.moveTo(w / 2, h * 0.72f)
                path.lineTo(w / 2, h * 0.28f)
            }
            "up" -> {
                path.moveTo(w / 2, h * 0.28f)
                path.lineTo(w / 2, h * 0.72f)
            }
            "left" -> {
                path.moveTo(w * 0.2f, h / 2)
                path.lineTo(w * 0.8f, h / 2)
            }
            "right" -> {
                path.moveTo(w * 0.8f, h / 2)
                path.lineTo(w * 0.2f, h / 2)
            }
            else -> return false
        }
        return swipe(path, 350)
    }

    private fun swipe(path: Path, durationMs: Long): Boolean {
        return try {
            val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
            dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        } catch (e: Exception) {
            false
        }
    }

    // ---------- system buttons ----------

    fun global(action: String): Boolean {
        val code = when (action.lowercase()) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "screenshot" -> {
                if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_TAKE_SCREENSHOT else return false
            }
            "lock" -> {
                if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_LOCK_SCREEN else return false
            }
            else -> return false
        }
        return performGlobalAction(code)
    }

    // ---------- find / tap / type ----------

    private fun allRoots(): List<AccessibilityNodeInfo> {
        val roots = ArrayList<AccessibilityNodeInfo>()
        try {
            rootInActiveWindow?.let { roots.add(it) }
        } catch (e: Exception) {
        }
        try {
            for (w in windows) {
                val r = w.root
                if (r != null) roots.add(r)
            }
        } catch (e: Exception) {
        }
        return roots
    }

    fun clickText(label: String): Boolean {
        if (label.isBlank()) return false
        for (root in allRoots()) {
            val nodes = try {
                root.findAccessibilityNodeInfosByText(label)
            } catch (e: Exception) {
                null
            } ?: continue
            for (n in nodes) {
                var cur: AccessibilityNodeInfo? = n
                var hops = 0
                while (cur != null && hops < 8) {
                    if (cur.isClickable && cur.isEnabled) {
                        if (cur.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
                    }
                    cur = cur.parent
                    hops++
                }
            }
        }
        return false
    }

    private fun findEditable(n: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        if (n == null) return null
        if (n.isEditable) return n
        for (i in 0 until n.childCount) {
            val r = findEditable(n.getChild(i))
            if (r != null) return r
        }
        return null
    }

    fun typeText(text: String): Boolean {
        for (root in allRoots()) {
            var node: AccessibilityNodeInfo? = null
            try {
                node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            } catch (e: Exception) {
            }
            if (node == null || !node.isEditable) node = findEditable(root)
            if (node == null) continue

            var existing = ""
            val cur = node.text
            val showingHint = Build.VERSION.SDK_INT >= 26 && node.isShowingHintText
            if (cur != null && !showingHint) existing = cur.toString()

            val args = Bundle()
            args.putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                existing + text
            )
            if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return true
        }
        return false
    }

    // ---------- screen recording (best effort, depends on the phone) ----------

    // Must be called from a background thread (it sleeps between steps).
    fun screenRecord(): Boolean {
        if (!performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)) return false
        Thread.sleep(1100)

        val tiles = listOf(
            "Screen record", "Screen recorder", "Screen recording",
            "Record screen", "Screenrecord", "Screen Capture"
        )
        var clicked = false
        for (attempt in 0 until 2) {
            for (t in tiles) {
                if (clickText(t)) {
                    clicked = true
                    break
                }
            }
            if (clicked) break
            // the tile may be on the next page of quick settings
            val dm = resources.displayMetrics
            val p = Path()
            p.moveTo(dm.widthPixels * 0.8f, dm.heightPixels * 0.25f)
            p.lineTo(dm.widthPixels * 0.2f, dm.heightPixels * 0.25f)
            swipe(p, 300)
            Thread.sleep(700)
        }
        if (!clicked) {
            performGlobalAction(GLOBAL_ACTION_BACK)
            return false
        }

        Thread.sleep(1300)
        val starts = listOf("Start now", "Start recording", "Start", "START", "Record")
        for (s in starts) {
            if (clickText(s)) break
        }
        return true
    }
}
