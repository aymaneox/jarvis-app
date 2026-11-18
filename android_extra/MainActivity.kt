package com.kaido.jarvis_app

import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "jarvis/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listApps" -> {
                        try {
                            val pm = packageManager
                            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                            val list = pm.queryIntentActivities(intent, 0)
                            val out = ArrayList<Map<String, String>>()
                            val seen = HashSet<String>()
                            for (ri in list) {
                                val pkg = ri.activityInfo.packageName
                                if (pkg == packageName || !seen.add(pkg)) continue
                                out.add(mapOf("name" to ri.loadLabel(pm).toString(), "package" to pkg))
                            }
                            result.success(out)
                        } catch (e: Exception) {
                            result.error("list_failed", e.message, null)
                        }
                    }
                    "launchApp" -> {
                        try {
                            val pkg = call.argument<String>("package")
                            val launch = if (pkg != null) packageManager.getLaunchIntentForPackage(pkg) else null
                            if (launch != null) {
                                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                applicationContext.startActivity(launch)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "startService" -> {
                        try {
                            val i = Intent(this, KeepAliveService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) {
                                startForegroundService(i)
                            } else {
                                startService(i)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopService" -> {
                        try {
                            stopService(Intent(this, KeepAliveService::class.java))
                        } catch (e: Exception) {
                        }
                        result.success(true)
                    }
                    "setOrb" -> {
                        val state = call.argument<String>("state") ?: "idle"
                        KeepAliveService.instance?.setOrb(state)
                        result.success(true)
                    }

                    // ----- accessibility (screen control) -----
                    "a11yEnabled" -> {
                        result.success(JarvisAccessibilityService.instance != null)
                    }
                    "openA11ySettings" -> {
                        try {
                            val i = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            applicationContext.startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "scroll" -> {
                        val s = JarvisAccessibilityService.instance
                        if (s == null) {
                            result.success("no_service")
                        } else {
                            result.success(s.scroll(call.argument<String>("direction") ?: "down"))
                        }
                    }
                    "global" -> {
                        val s = JarvisAccessibilityService.instance
                        if (s == null) {
                            result.success("no_service")
                        } else {
                            result.success(s.global(call.argument<String>("action") ?: ""))
                        }
                    }
                    "clickText" -> {
                        val s = JarvisAccessibilityService.instance
                        if (s == null) {
                            result.success("no_service")
                        } else {
                            result.success(s.clickText(call.argument<String>("text") ?: ""))
                        }
                    }
                    "typeText" -> {
                        val s = JarvisAccessibilityService.instance
                        if (s == null) {
                            result.success("no_service")
                        } else {
                            result.success(s.typeText(call.argument<String>("text") ?: ""))
                        }
                    }
                    "screenRecord" -> {
                        val s = JarvisAccessibilityService.instance
                        if (s == null) {
                            result.success("no_service")
                        } else {
                            Thread {
                                val ok = try {
                                    s.screenRecord()
                                } catch (e: Exception) {
                                    false
                                }
                                Handler(Looper.getMainLooper()).post { result.success(ok) }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
