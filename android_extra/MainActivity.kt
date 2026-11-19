package com.kaido.jarvis_app

import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Settings
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "jarvis/native"

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        NotificationBridge.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {

                // ----- apps -----
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
                "waitForApp" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    val timeout = (call.argument<Number>("timeoutMs") ?: 3000).toLong()
                    val s = JarvisAccessibilityService.instance
                    Thread {
                        var ok = false
                        if (s == null) {
                            Thread.sleep(1200)
                            ok = true
                        } else {
                            val end = System.currentTimeMillis() + timeout
                            while (System.currentTimeMillis() < end) {
                                if (s.currentPackage() == pkg) {
                                    ok = true
                                    break
                                }
                                Thread.sleep(150)
                            }
                            if (ok) Thread.sleep(350)
                        }
                        Handler(Looper.getMainLooper()).post { result.success(ok) }
                    }.start()
                }

                // ----- service / orb / keep alive -----
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
                "heartbeat" -> {
                    KeepAliveService.lastBeat = System.currentTimeMillis()
                    result.success(true)
                }
                "launchedInBackground" -> {
                    result.success(intent?.getBooleanExtra("jarvis_bg", false) ?: false)
                }
                "moveToBack" -> {
                    try {
                        moveTaskToBack(true)
                    } catch (e: Exception) {
                    }
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
                    if (s == null) result.success("no_service")
                    else result.success(s.scroll(call.argument<String>("direction") ?: "down"))
                }
                "global" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) result.success("no_service")
                    else result.success(s.global(call.argument<String>("action") ?: ""))
                }
                "clickText" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) result.success("no_service")
                    else result.success(s.clickText(call.argument<String>("text") ?: ""))
                }
                "typeText" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) result.success("no_service")
                    else result.success(s.typeText(call.argument<String>("text") ?: ""))
                }
                "tapAt" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) {
                        result.success("no_service")
                    } else {
                        val x = (call.argument<Number>("x") ?: 500).toDouble()
                        val y = (call.argument<Number>("y") ?: 500).toDouble()
                        result.success(s.tapAt(x, y))
                    }
                }
                "longPressAt" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) {
                        result.success("no_service")
                    } else {
                        val x = (call.argument<Number>("x") ?: 500).toDouble()
                        val y = (call.argument<Number>("y") ?: 500).toDouble()
                        result.success(s.longPressAt(x, y))
                    }
                }
                "swipeAt" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) {
                        result.success("no_service")
                    } else {
                        val x1 = (call.argument<Number>("x1") ?: 500).toDouble()
                        val y1 = (call.argument<Number>("y1") ?: 700).toDouble()
                        val x2 = (call.argument<Number>("x2") ?: 500).toDouble()
                        val y2 = (call.argument<Number>("y2") ?: 300).toDouble()
                        result.success(s.swipeAt(x1, y1, x2, y2, 350))
                    }
                }
                "screenshotJpeg" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) {
                        result.success(null)
                    } else {
                        s.screenshotJpeg { bytes -> result.success(bytes) }
                    }
                }
                "describeScreen" -> {
                    val s = JarvisAccessibilityService.instance
                    if (s == null) result.success("") else result.success(s.describeScreen())
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

                // ----- notifications -----
                "notifAccessEnabled" -> {
                    val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
                    result.success(enabled.contains(packageName))
                }
                "openNotifSettings" -> {
                    try {
                        val i = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        applicationContext.startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "replyNotification" -> {
                    val s = JarvisNotificationService.instance
                    val ok = s?.reply(call.argument<String>("key") ?: "", call.argument<String>("text") ?: "") ?: false
                    result.success(ok)
                }
                "openNotification" -> {
                    val s = JarvisNotificationService.instance
                    result.success(s?.open(call.argument<String>("key") ?: "") ?: false)
                }

                // ----- phone skills -----
                "torch" -> {
                    try {
                        val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                        var id: String? = null
                        for (cid in cm.cameraIdList) {
                            val flash = cm.getCameraCharacteristics(cid).get(CameraCharacteristics.FLASH_INFO_AVAILABLE)
                            if (flash == true) {
                                id = cid
                                break
                            }
                        }
                        if (id != null) {
                            cm.setTorchMode(id, call.argument<Boolean>("on") ?: true)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "volume" -> {
                    try {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        when (call.argument<String>("mode") ?: "up") {
                            "set" -> {
                                val lvl = (call.argument<Number>("level") ?: 50).toInt().coerceIn(0, 100)
                                am.setStreamVolume(AudioManager.STREAM_MUSIC, max * lvl / 100, AudioManager.FLAG_SHOW_UI)
                            }
                            "down" -> am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
                            "mute" -> am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, AudioManager.FLAG_SHOW_UI)
                            else -> am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "media" -> {
                    try {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val code = when (call.argument<String>("action") ?: "play_pause") {
                            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
                            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
                            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
                            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
                            else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                        }
                        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "contactNumber" -> {
                    try {
                        val name = call.argument<String>("name") ?: ""
                        var number = ""
                        val cursor = contentResolver.query(
                            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                            arrayOf(
                                ContactsContract.CommonDataKinds.Phone.NUMBER,
                                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
                            ),
                            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " LIKE ?",
                            arrayOf("%" + name + "%"),
                            null
                        )
                        if (cursor != null) {
                            if (cursor.moveToFirst()) number = cursor.getString(0) ?: ""
                            cursor.close()
                        }
                        result.success(number)
                    } catch (e: Exception) {
                        result.success("")
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        NotificationBridge.channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
