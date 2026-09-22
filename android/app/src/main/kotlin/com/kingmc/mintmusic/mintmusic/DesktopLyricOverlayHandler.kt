package com.kingmc.mintmusic.mintmusic

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * 桌面歌词的系统级悬浮窗(Android)。
 *
 * 实现参考 lx-music-mobile 的 `LyricView.java`:
 * - 用 `WindowManager.addView` 挂一个 `TYPE_APPLICATION_OVERLAY` 窗口,
 *   因此歌词可以显示在其它应用之上;
 * - 锁定时追加 `FLAG_NOT_TOUCHABLE`,触摸事件完全穿透到下层应用;
 * - 拖动结束时把像素坐标换算成**屏幕百分比**回传给 Dart 保存,
 *   这样屏幕旋转/尺寸变化后位置依旧相对一致。
 *
 * 歌词行使用原生 TextView 渲染:单行模式直接使用系统跑马灯
 * (`TruncateAt.MARQUEE`),无需在悬浮窗里再跑一个 FlutterEngine。
 */
class DesktopLyricOverlayHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    private data class LyricLineData(
        val time: Long,
        val text: String,
        val translation: String?,
        val roman: String?,
    )

    /** 一行待渲染的歌词:`isSub` 表示它是当前行的翻译/罗马音。 */
    private data class LyricRow(
        val text: String,
        val active: Boolean,
        val isSub: Boolean,
    )

    private val appContext = context.applicationContext
    private val windowManager: WindowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var rootView: FrameLayout? = null
    private var lineContainer: LinearLayout? = null
    private var textViews: MutableList<TextView> = mutableListOf()
    private var layoutParams: WindowManager.LayoutParams? = null
    private var backgroundDrawable: GradientDrawable? = null

    // ---- 配置 ----
    private var isLock = false
    private var isSingleLine = false
    private var maxLineNum = 5
    private var fontSizeSp = 18f
    private var opacity = 1f
    private var widthPercent = 100
    private var playedColor = Color.parseColor("#07C556")
    private var unplayColor = Color.WHITE
    private var shadowColor = Color.argb(153, 0, 0, 0)
    private var alignX = Gravity.START
    private var alignY = Gravity.TOP
    private var positionXPercent = 3.0
    private var positionYPercent = 8.0

    // ---- 歌词数据 ----
    private var lines: List<LyricLineData> = emptyList()
    private var activeIndex = 0
    private var showTranslation = true
    private var showRoman = true

    // ---- 拖动状态 ----
    private var lastTouchRawX = 0f
    private var lastTouchRawY = 0f
    private var dragging = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermission" -> result.success(hasOverlayPermission())
            "openPermissionSettings" -> result.success(openPermissionSettings())
            "show" -> result.success(show())
            "hide" -> {
                hide()
                result.success(true)
            }
            "isShowing" -> result.success(rootView != null)
            "updateConfig" -> {
                applyConfig(call.arguments as? Map<*, *>)
                result.success(true)
            }
            "updateLyric" -> {
                updateLyric(call.arguments as? Map<*, *>)
                result.success(true)
            }
            "updateActiveIndex" -> {
                val index = (call.arguments as? Number)?.toInt() ?: 0
                setActiveIndex(index)
                result.success(true)
            }
            "setPlayState" -> {
                val args = call.arguments as? Map<*, *>
                val positionMs = (args?.get("positionMs") as? Number)?.toLong() ?: 0L
                applyPlayState(positionMs, args?.get("isPlaying") == true)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ 权限

    private fun hasOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(appContext)
        } else {
            true
        }
    }

    private fun openPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${appContext.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }

    // ------------------------------------------------------------- 窗口生命周期

    private fun show(): Boolean {
        if (rootView != null) {
            render()
            return true
        }
        // 清理上一次运行(例如热重启)遗留的窗口,避免歌词窗重复叠加。
        releaseOrphanWindow()
        if (!hasOverlayPermission()) return false

        val root = FrameLayout(appContext)
        val container = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(
            container,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                alignY or alignX,
            ),
        )

        val lp = WindowManager.LayoutParams().apply {
            width = (screenWidth() * widthPercent / 100f).roundToInt().coerceAtLeast(120)
            height = WindowManager.LayoutParams.WRAP_CONTENT
            type = overlayWindowType()
            format = PixelFormat.TRANSLUCENT
            gravity = Gravity.TOP or Gravity.START
            flags = buildFlags()
            alpha = windowAlpha()
        }

        root.setOnTouchListener(createTouchListener(root))

        return try {
            windowManager.addView(root, lp)
            activeRoot = root
            activeWindowManager = windowManager
            rootView = root
            lineContainer = container
            layoutParams = lp
            applyBackground()
            rebuildTextViews()
            render()
            // 首帧之后才能拿到真实高度,再按百分比精确定位一次。
            root.post { applyPositionPercent() }
            true
        } catch (error: Throwable) {
            android.util.Log.w("DesktopLyricOverlay", "addView failed", error)
            rootView = null
            lineContainer = null
            layoutParams = null
            false
        }
    }

    private fun hide() {
        val root = rootView ?: return
        stopTicker()
        try {
            windowManager.removeView(root)
        } catch (_: Throwable) {
            // 窗口可能已经被系统回收。
        }
        if (activeRoot === root) {
            activeRoot = null
            activeWindowManager = null
        }
        rootView = null
        lineContainer = null
        layoutParams = null
        textViews.clear()
    }

    @Suppress("DEPRECATION")
    private fun overlayWindowType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }
    }

    private fun buildFlags(): Int {
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        // 锁定 = 整个窗口不可触摸,事件穿透到下层应用。
        if (isLock) flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        return flags
    }

    // Android 12+ 系统对悬浮窗有最大不透明度限制,锁定态需要主动降到 0.8
    // 才能真正实现点击穿透(与 lx-music 的处理一致)。
    private fun windowAlpha(): Float {
        return if (isLock && Build.VERSION.SDK_INT > Build.VERSION_CODES.R) {
            opacity.coerceAtMost(0.8f)
        } else {
            opacity
        }
    }

    // ------------------------------------------------------------------ 配置

    private fun applyConfig(args: Map<*, *>?) {
        if (args == null) return
        isLock = args["isLock"] == true
        isSingleLine = args["isSingleLine"] == true
        maxLineNum = (args["maxLineNum"] as? Number)?.toInt()?.coerceIn(1, 8) ?: maxLineNum
        fontSizeSp = (args["fontSize"] as? Number)?.toFloat()?.coerceIn(12f, 40f) ?: fontSizeSp
        opacity = ((args["opacityPercent"] as? Number)?.toFloat() ?: 100f) / 100f
        widthPercent = (args["widthPercent"] as? Number)?.toInt()?.coerceIn(10, 100) ?: widthPercent
        playedColor = (args["playedColor"] as? Number)?.toInt() ?: playedColor
        unplayColor = (args["unplayColor"] as? Number)?.toInt() ?: unplayColor
        shadowColor = (args["shadowColor"] as? Number)?.toInt() ?: shadowColor
        positionXPercent = (args["positionX"] as? Number)?.toDouble() ?: positionXPercent
        positionYPercent = (args["positionY"] as? Number)?.toDouble() ?: positionYPercent

        alignX = when (args["textAlignX"] as? String) {
            "center" -> Gravity.CENTER_HORIZONTAL
            "right" -> Gravity.END
            else -> Gravity.START
        }
        alignY = when (args["textAlignY"] as? String) {
            "center" -> Gravity.CENTER_VERTICAL
            "bottom" -> Gravity.BOTTOM
            else -> Gravity.TOP
        }

        val root = rootView ?: return
        val lp = layoutParams ?: return
        lp.flags = buildFlags()
        lp.alpha = windowAlpha()
        lp.width = (screenWidth() * widthPercent / 100f).roundToInt().coerceAtLeast(120)
        (lineContainer?.layoutParams as? FrameLayout.LayoutParams)?.gravity = alignY or alignX
        applyBackground()
        root.setOnTouchListener(createTouchListener(root))
        rebuildTextViews()
        render()
        root.post { applyPositionPercent() }
        safeUpdateLayout()
    }

    private fun applyBackground() {
        val root = rootView ?: return
        val drawable = backgroundDrawable ?: GradientDrawable().also { backgroundDrawable = it }
        drawable.cornerRadius = 10f * appContext.resources.displayMetrics.density
        if (isLock) {
            drawable.setColor(Color.TRANSPARENT)
            drawable.setStroke(0, Color.TRANSPARENT)
        } else {
            drawable.setColor(Color.argb(41, 0, 0, 0))
            drawable.setStroke(1, Color.argb(56, 255, 255, 255))
        }
        root.background = drawable
    }

    // ------------------------------------------------------------------ 歌词

    private fun updateLyric(args: Map<*, *>?) {
        val raw = args?.get("lines") as? List<*> ?: return
        lines = raw.mapNotNull { item ->
            val map = item as? Map<*, *> ?: return@mapNotNull null
            LyricLineData(
                time = (map["time"] as? Number)?.toLong() ?: 0L,
                text = map["text"] as? String ?: "",
                translation = map["translation"] as? String,
                roman = map["roman"] as? String,
            )
        }
        showTranslation = args["showTranslation"] != false
        showRoman = args["showRoman"] != false
        setActiveIndex((args["activeIndex"] as? Number)?.toInt() ?: 0)
    }

    private fun setActiveIndex(index: Int) {
        activeIndex = index
        render()
    }

    private fun rebuildTextViews() {
        val container = lineContainer ?: return
        val target = if (isSingleLine) 1 else maxLineNum
        while (textViews.size > target) {
            container.removeView(textViews.removeAt(textViews.size - 1))
        }
        while (textViews.size < target) {
            val tv = TextView(appContext).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
                includeFontPadding = false
                setLineSpacing(0f, 1.25f)
            }
            textViews.add(tv)
            container.addView(
                tv,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        textViews.forEach { it.visibility = View.GONE }
    }

    /** 与 Dart 侧 `DesktopLyricPanel._buildRows` 保持一致的取行规则。 */
    private fun buildRows(): List<LyricRow> {
        if (lines.isEmpty()) return emptyList()
        val index = activeIndex.coerceIn(0, lines.size - 1)
        val rows = mutableListOf<LyricRow>()
        val max = if (isSingleLine) 1 else maxLineNum

        for (i in index until lines.size) {
            if (rows.size >= max) break
            val line = lines[i]
            if (line.text.isNotBlank()) {
                rows.add(LyricRow(line.text, active = i == index, isSub = false))
            }
            if (i != index) continue
            if (showTranslation && !line.translation.isNullOrBlank() && rows.size < max) {
                rows.add(LyricRow(line.translation!!, active = true, isSub = true))
            }
            if (showRoman && !line.roman.isNullOrBlank() && rows.size < max) {
                rows.add(LyricRow(line.roman!!, active = true, isSub = true))
            }
        }
        return rows
    }

    private fun render() {
        val container = lineContainer ?: return
        if (textViews.size != (if (isSingleLine) 1 else maxLineNum)) rebuildTextViews()
        val views = textViews

        if (isSingleLine) {
            val text = lines.getOrNull(activeIndex.coerceIn(0, (lines.size - 1).coerceAtLeast(0)))?.text
            val first = views.firstOrNull() ?: return
            first.visibility = View.VISIBLE
            first.text = text ?: ""
            first.setTextColor(playedColor)
            first.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
            first.gravity = Gravity.CENTER_VERTICAL or alignX
            first.setShadowLayer(4f, 1f, 1f, shadowColor)
            // 单行且超长时使用系统跑马灯横向滚动。
            first.setSingleLine()
            first.ellipsize = TextUtils.TruncateAt.MARQUEE
            first.marqueeRepeatLimit = -1
            first.isSelected = true
            for (i in 1 until views.size) views[i].visibility = View.GONE
            safeUpdateLayout()
            return
        }

        val rows = buildRows()
        for (i in views.indices) {
            val tv = views[i]
            if (i >= rows.size) {
                tv.visibility = View.GONE
                continue
            }
            val row = rows[i]
            tv.visibility = View.VISIBLE
            tv.text = row.text
            tv.setTextColor(if (row.active) playedColor else unplayColor)
            // 翻译/罗马音行比主行小一号。
            tv.setTextSize(
                TypedValue.COMPLEX_UNIT_SP,
                if (row.isSub) fontSizeSp * 0.62f else fontSizeSp,
            )
            tv.gravity = Gravity.CENTER_VERTICAL or alignX
            tv.setShadowLayer(4f, 1f, 1f, shadowColor)
            tv.setSingleLine()
            tv.ellipsize = TextUtils.TruncateAt.END
            tv.isSelected = false
            tv.marqueeRepeatLimit = 0
        }
        safeUpdateLayout()
    }

    // ------------------------------------------------------------------ 拖动

    @SuppressLint("ClickableViewAccessibility")
    private fun createTouchListener(root: FrameLayout): View.OnTouchListener {
        return View.OnTouchListener { _, event ->
            val lp = layoutParams ?: return@OnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    lastTouchRawX = event.rawX
                    lastTouchRawY = event.rawY
                    dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - lastTouchRawX
                    val dy = event.rawY - lastTouchRawY
                    lastTouchRawX = event.rawX
                    lastTouchRawY = event.rawY
                    lp.x = (lp.x + dx).roundToInt().coerceIn(0, maxOffsetX(root))
                    lp.y = (lp.y + dy).roundToInt().coerceIn(0, maxOffsetY(root))
                    dragging = true
                    safeUpdateLayout()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) notifyPositionChanged(root)
                    dragging = false
                    true
                }
                else -> false
            }
        }
    }

    // --------------------------------------------------- 歌词时钟(原生侧推进)
    //
    // 应用退到后台后,Dart 侧的进度回调不可靠(可能被节流/暂停),
    // 所以这里与 lx-music 的 LyricPlayer 一样:Dart 只下发一次「进度锚点」,
    // 之后由原生侧用单调时钟自行推进当前行。
    private val mainHandler = Handler(Looper.getMainLooper())
    private var tickerRunning = false
    private var playing = false
    private var anchorMediaMs = 0L
    private var anchorElapsedMs = 0L
    private var lastKnownMediaMs = 0L

    private val tickRunnable = object : Runnable {
        override fun run() {
            tick()
            if (tickerRunning) mainHandler.postDelayed(this, 250L)
        }
    }

    /** 设置进度锚点;Dart 会定期重新下发以校准漂移。 */
    private fun applyPlayState(positionMs: Long, isPlaying: Boolean) {
        lastKnownMediaMs = positionMs
        anchorMediaMs = positionMs
        anchorElapsedMs = SystemClock.elapsedRealtime()
        playing = isPlaying

        if (isPlaying && !tickerRunning && rootView != null) {
            tickerRunning = true
            mainHandler.post(tickRunnable)
        } else if (!isPlaying) {
            tickerRunning = false
            mainHandler.removeCallbacks(tickRunnable)
        }
        // 立刻同步一次,暂停/跳转也能马上刷新。
        setActiveIndex(indexForTime(currentMediaTimeMs()))
    }

    private fun tick() {
        if (!playing) return
        setActiveIndex(indexForTime(currentMediaTimeMs()))
    }

    private fun currentMediaTimeMs(): Long {
        if (!playing) return lastKnownMediaMs
        return anchorMediaMs + (SystemClock.elapsedRealtime() - anchorElapsedMs)
    }

    /** 与 Dart 侧 `lastIndexWhere(startTimeMs <= t)` 相同。 */
    private fun indexForTime(timeMs: Long): Int {
        if (lines.isEmpty()) return 0
        var index = 0
        for (i in lines.indices) {
            if (lines[i].time <= timeMs) index = i else break
        }
        return index
    }

    private fun stopTicker() {
        tickerRunning = false
        playing = false
        mainHandler.removeCallbacks(tickRunnable)
    }

    /** 拖动结束:像素坐标 -> 百分比,回传给 Dart 持久化。 */
    private fun notifyPositionChanged(root: FrameLayout) {
        val lp = layoutParams ?: return
        val maxX = maxOffsetX(root)
        val maxY = maxOffsetY(root)
        val xPercent = if (maxX <= 0) 0.0 else (lp.x.toDouble() / maxX * 100.0)
        val yPercent = if (maxY <= 0) 0.0 else (lp.y.toDouble() / maxY * 100.0)
        positionXPercent = xPercent
        positionYPercent = yPercent
        channel?.invokeMethod(
            "onPositionChanged",
            mapOf("x" to xPercent, "y" to yPercent),
        )
    }

    private fun applyPositionPercent() {
        val root = rootView ?: return
        val lp = layoutParams ?: return
        lp.x = (maxOffsetX(root) * positionXPercent / 100.0).roundToInt()
            .coerceIn(0, maxOffsetX(root))
        lp.y = (maxOffsetY(root) * positionYPercent / 100.0).roundToInt()
            .coerceIn(0, maxOffsetY(root))
        safeUpdateLayout()
    }

    private fun maxOffsetX(root: View): Int {
        val vw = if (root.width > 0) root.width else (screenWidth() * widthPercent / 100f).roundToInt()
        return (screenWidth() - vw).coerceAtLeast(0)
    }

    private fun maxOffsetY(root: View): Int {
        val vh = if (root.height > 0) root.height else 0
        return (screenHeight() - vh).coerceAtLeast(0)
    }

    private fun safeUpdateLayout() {
        val root = rootView ?: return
        val lp = layoutParams ?: return
        try {
            windowManager.updateViewLayout(root, lp)
        } catch (_: Throwable) {
            // 窗口可能已被移除。
        }
    }

    private fun screenWidth(): Int = appContext.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = appContext.resources.displayMetrics.heightPixels

    /** 由 MainActivity 注入,用于把拖动后的位置回传给 Dart。 */
    private var channel: MethodChannel? = null

    fun attachChannel(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    companion object {
        /** 当前挂在 WindowManager 上的窗口,用于跨引擎实例清理残留。 */
        private var activeRoot: View? = null
        private var activeWindowManager: WindowManager? = null

        private fun releaseOrphanWindow() {
            val root = activeRoot ?: return
            try {
                activeWindowManager?.removeView(root)
            } catch (_: Throwable) {
                // 窗口可能已经被系统回收。
            }
            activeRoot = null
            activeWindowManager = null
        }
    }
}
