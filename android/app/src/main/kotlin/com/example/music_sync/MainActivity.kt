package com.example.music_sync

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        private const val HOTSPOT_CHANNEL = "mysend/wifi"
        private const val HOTSPOT_PERMISSION_REQUEST = 2001
    }

    private var hotspotExecutor: ExecutorService? = null
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var pendingHotspot: MethodChannel.Result? = null
    private var pendingSsid: String = ""
    private var pendingPassphrase: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyFullscreen()
        // 启动后台保活服务（前台服务 + 常驻通知），保持局域网接收服务在线。
        SyncKeepAliveService.start(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HOTSPOT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startHotspot" -> startHotspot(call, result)
                    "stopHotspot" -> stopHotspot(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startHotspot(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.error("unsupported", "需要 Android 13 及以上", null)
            return
        }
        val ssid = call.argument<String>("ssid") ?: "MySend"
        val passphrase = call.argument<String>("passphrase") ?: "00000000"
        pendingSsid = ssid
        pendingPassphrase = passphrase
        pendingHotspot = result

        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.NEARBY_WIFI_DEVICES
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            beginLocalOnlyHotspot()
        } else {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES),
                HOTSPOT_PERMISSION_REQUEST
            )
        }
    }

    private fun stopHotspot(result: MethodChannel.Result) {
        try {
            hotspotReservation?.close()
        } catch (_: Throwable) {
        }
        hotspotReservation = null
        result.success(null)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == HOTSPOT_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                beginLocalOnlyHotspot()
            } else {
                pendingHotspot?.error("permission_denied", "未授予「附近设备」权限", null)
                pendingHotspot = null
            }
        }
    }

    private fun beginLocalOnlyHotspot() {
        val manager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val config = try {
            SoftApConfiguration.Builder()
                .setSsid(pendingSsid)
                .setPassphrase(pendingPassphrase, SoftApConfiguration.SECURITY_TYPE_WPA2_PSK)
                .build()
        } catch (e: Throwable) {
            pendingHotspot?.error("config_error", "${e.message}", null)
            pendingHotspot = null
            return
        }
        val executor = Executors.newSingleThreadExecutor()
        hotspotExecutor = executor
        try {
            manager.startLocalOnlyHotspot(
                config,
                executor,
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspotReservation = reservation
                        pendingHotspot?.success(true)
                        pendingHotspot = null
                    }

                    override fun onStopped() {
                        hotspotReservation = null
                    }

                    override fun onFailed(reason: Int) {
                        hotspotReservation = null
                        pendingHotspot?.error("hotspot_failed", "开启热点失败，原因码 $reason", null)
                        pendingHotspot = null
                    }
                }
            )
        } catch (e: Throwable) {
            pendingHotspot?.error("hotspot_exception", "${e.message}", null)
            pendingHotspot = null
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyFullscreen()
    }

    private fun applyFullscreen() {
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        // 1) 内容铺满到状态栏/挖孔区域（edge-to-edge）
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // 2) 程序化指定挖孔显示模式。关键点有二：
        //    a) edge-to-edge / 隐藏状态栏时用 ALWAYS（而非 SHORT_EDGES），
        //       因为 SHORT_EDGES 在窗口处于全屏/沉浸态时会被系统当作不铺满挖孔；
        //    b) 必须取副本、改字段、再整体回写 setAttributes，直接改字段不生效。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val lp = window.attributes
            lp.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            window.attributes = lp
        }
        // 3) 旧式沉浸全屏 flags（部分国产 ROM 对 WindowInsetsController 不敏感，双保险）
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            )
        // 4) 现代 WindowInsetsController 隐藏状态栏
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.statusBars())
    }
}