/**
 * AMLL Lyric Player WebView Bridge Entry
 *
 * Builds a standalone JS bundle that can run in a Flutter WebView.
 * Only includes the lyric player (no Pixi background renderer).
 */

import { LyricPlayer, LayoutAlignAnchor, MaskObsceneWordsMode } from '@applemusic-like-lyrics/core'

let player = null
let restoreBlockedTouchListeners = null
let pendingTimeAfterScroll = null

function postToFlutter(detail) {
  try {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('AmllChannel', JSON.stringify(detail))
    }
  } catch {}
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}

function clampScrollState(state) {
  const boundary = state.scrollBoundary || { minOffset: 0, maxOffset: 0 }
  state.scrollOffset = clamp(
    state.scrollOffset || 0,
    boundary.minOffset || 0,
    boundary.maxOffset || 0
  )
}

function blockCoreTouchScrollListeners() {
  const originalAddEventListener = EventTarget.prototype.addEventListener
  EventTarget.prototype.addEventListener = function (type, listener, options) {
    const isLyricElement =
      this instanceof HTMLElement &&
      this.classList &&
      this.classList.contains('amll-lyric-player')
    if (
      isLyricElement &&
      (type === 'touchstart' || type === 'touchmove' || type === 'touchend')
    ) {
      return
    }
    return originalAddEventListener.call(this, type, listener, options)
  }
  return function restore() {
    EventTarget.prototype.addEventListener = originalAddEventListener
  }
}

function installStableTouchScroll() {
  if (!player) return
  const element = player.getElement()
  const state = player.scrollState
  if (!element || !state || element.__mintStableTouchScrollInstalled) return
  element.__mintStableTouchScrollInstalled = true

  let startOffset = 0
  let startX = 0
  let startY = 0
  let lastY = 0
  let lastTime = 0
  let velocity = 0
  let flingToken = 0

  function beginScroll() {
    if (typeof player.beginScrollHandler === 'function') {
      return player.beginScrollHandler()
    }
    return state.allowScroll !== false
  }

  function endScroll() {
    state.isUserScrolling = false
    if (typeof player.endScrollHandler === 'function') player.endScrollHandler()
    postToFlutter({ type: 'interaction-end' })
    if (pendingTimeAfterScroll !== null) {
      const time = pendingTimeAfterScroll
      pendingTimeAfterScroll = null
      requestAnimationFrame(function () {
        if (player && !player.scrollState?.isUserScrolling) {
          player.setCurrentTime(time)
        }
      })
    }
  }

  function relayout(useSpring) {
    if (typeof player.calcLayout === 'function') {
      player.calcLayout(true, useSpring)
    }
  }

  function onTouchStart(event) {
    if (event.touches.length !== 1 || !beginScroll()) return
    event.preventDefault()
    event.stopImmediatePropagation()

    const touch = event.touches[0]
    flingToken++
    state.isUserScrolling = true
    startOffset = state.scrollOffset || 0
    startX = touch.clientX
    startY = touch.clientY
    lastY = startY
    lastTime = performance.now()
    velocity = 0
    relayout(true)
    postToFlutter({ type: 'interaction-start' })
  }

  function onTouchMove(event) {
    if (!state.isUserScrolling || event.touches.length !== 1) return
    event.preventDefault()
    event.stopImmediatePropagation()

    const touch = event.touches[0]
    const y = touch.clientY
    const dy = y - startY
    state.scrollOffset = startOffset - dy
    clampScrollState(state)

    const now = performance.now()
    const dt = Math.max(1, now - lastTime)
    velocity = clamp((y - lastY) / dt, -1.15, 1.15)
    lastY = y
    lastTime = now
    relayout(true)
  }

  function onTouchEnd(event) {
    if (!state.isUserScrolling) return
    event.preventDefault()
    event.stopImmediatePropagation()

    const touch = event.changedTouches[0]
    const movedX = Math.abs(touch.clientX - startX)
    const movedY = Math.abs(touch.clientY - startY)
    if (movedX < 10 && movedY < 10) {
      const target = document.elementFromPoint(touch.clientX, touch.clientY)
      if (target instanceof HTMLElement && element.contains(target)) {
        target.click()
      }
      endScroll()
      return
    }

    const token = ++flingToken
    let lastFrame = performance.now()
    let currentVelocity = Math.abs(velocity) < 0.035 ? 0 : velocity

    function step(now) {
      if (token !== flingToken) return
      const dt = Math.min(48, Math.max(1, now - lastFrame))
      lastFrame = now

      if (Math.abs(currentVelocity) <= 0.025) {
        endScroll()
        return
      }

      const before = state.scrollOffset
      state.scrollOffset -= currentVelocity * dt
      clampScrollState(state)
      if (Math.abs(before - state.scrollOffset) < 0.1) {
        currentVelocity = 0
      } else {
        currentVelocity *= Math.pow(0.90, dt / 16)
      }
      relayout(true)
      requestAnimationFrame(step)
    }

    requestAnimationFrame(step)
  }

  element.addEventListener('touchstart', onTouchStart, { passive: false, capture: true })
  element.addEventListener('touchmove', onTouchMove, { passive: false, capture: true })
  element.addEventListener('touchend', onTouchEnd, { passive: false, capture: true })
  element.addEventListener('touchcancel', function (event) {
    if (!state.isUserScrolling) return
    event.preventDefault()
    event.stopImmediatePropagation()
    flingToken++
    endScroll()
  }, { passive: false, capture: true })
}

// == Initialization ==
function initLyricPlayer(containerId) {
  const container = document.getElementById(containerId)
  if (!container) throw new Error('Container #' + containerId + ' not found')

  restoreBlockedTouchListeners = blockCoreTouchScrollListeners()
  try {
    player = new LyricPlayer()
  } finally {
    restoreBlockedTouchListeners()
    restoreBlockedTouchListeners = null
  }
  container.appendChild(player.getElement())
  installStableTouchScroll()

  // dispatch line-click events back to Flutter
  player.addEventListener('line-click', function (e) {
    try {
      // 方法1: 从事件对象获取
      var startTime = e.line ? e.line.startTime : -1
      
      // 方法2: 通过 lineIndex 从歌词数据回溯（更可靠）
      if ((startTime === undefined || startTime === null || startTime < 0) && e.lineIndex >= 0 && player.currentLyricLines) {
        var dataLine = player.currentLyricLines[e.lineIndex]
        if (dataLine && typeof dataLine.startTime === 'number') {
          startTime = dataLine.startTime
        }
      }
      
      // 兜底: 如果还是没有，用 0
      if (startTime === undefined || startTime === null || startTime < 0) startTime = 0
      
      const detail = {
        type: 'line-click',
        lineIndex: e.lineIndex,
        startTime: startTime
      }
      postToFlutter(detail)
    } catch (ex) {
      console.warn('[AmllBridge] line-click handler error:', ex)
    }
  })

  return true
}

// == Set lyric lines ==
function setLyricLines(jsonStr, initialTime = 0) {
  if (!player) return
  try {
    const lines = JSON.parse(jsonStr)
    player.setLyricLines(lines, initialTime)
  } catch (ex) {
    console.warn('[AmllBridge] setLyricLines error:', ex)
  }
}

// == Update playback position (ms) ==
let _lastTime = -1
function setCurrentTime(ms) {
  if (!player) return
  _lastTime = ms
  if (player.scrollState?.isUserScrolling) {
    pendingTimeAfterScroll = ms
    return
  }
  player.setCurrentTime(ms)
}

// == Play / Pause ==
function setPlaying(playing) {
  if (!player) return
  if (playing) player.resume()
  else player.pause()
}

// == Update visual config ==
function setConfig(jsonStr) {
  if (!player) return
  try {
    const cfg = JSON.parse(jsonStr)
    if (cfg.enableBlur !== undefined) player.setEnableBlur(cfg.enableBlur)
    if (cfg.enableScale !== undefined) player.setEnableScale(cfg.enableScale)
    if (cfg.enableSpring !== undefined) player.setEnableSpring(cfg.enableSpring)
    if (cfg.alignPosition !== undefined) player.setAlignPosition(cfg.alignPosition)
    if (cfg.wordFadeWidth !== undefined) player.setWordFadeWidth(cfg.wordFadeWidth)
    if (cfg.hidePassedLines !== undefined) player.setHidePassedLines(cfg.hidePassedLines)
    // 字体配置（参照 CeruMusic: 通过 CSS 变量控制 AMLL LyricPlayer 字体）
    const el = player.getElement()
    if (el) {
      // fontFamily: 空字符串或 'system' 使用默认字体，其他直接应用
      if (cfg.fontFamily !== undefined) {
        var ff = (cfg.fontFamily || '').trim()
        if (!ff || ff === 'system') {
          ff = 'sans-serif'
        }
        el.style.fontFamily = ff
      }
      // fontSizeRate: 调整 --amll-lp-font-size 的倍率
      if (cfg.fontSizeRate !== undefined && cfg.fontSizeRate !== 1.0) {
        var base = 'calc(min(clamp(30px,2.5vw,50px),5vh) * ' + cfg.fontSizeRate + ')'
        el.style.setProperty('--amll-lp-font-size', base)
      } else if (cfg.fontSizeRate !== undefined) {
        el.style.setProperty('--amll-lp-font-size', 'calc(min(clamp(30px,2.5vw,50px),5vh))')
      }
      // fontWeight
      if (cfg.fontWeight !== undefined) {
        el.style.fontWeight = String(cfg.fontWeight)
      }
      if (cfg.centerAlign !== undefined) {
        el.style.setProperty('--amll-lp-text-align', cfg.centerAlign ? 'center' : 'left')
      }
    }
  } catch (ex) {
    console.warn('[AmllBridge] setConfig error:', ex)
  }
}

// == Dispose ==
function dispose() {
  if (restoreBlockedTouchListeners) {
    restoreBlockedTouchListeners()
    restoreBlockedTouchListeners = null
  }
  if (player) {
    player.dispose()
    player = null
  }
}

// == Per-frame animation update (called from requestAnimationFrame) ==
let _rafId = null
let _lastRafTime = 0

function _startAnimationLoop() {
  if (_rafId) return
  _lastRafTime = performance.now()
  function tick(now) {
    const delta = now - _lastRafTime
    _lastRafTime = now
    if (player) {
      player.update(delta)
    }
    _rafId = requestAnimationFrame(tick)
  }
  _rafId = requestAnimationFrame(tick)
}

function _stopAnimationLoop() {
  if (_rafId) {
    cancelAnimationFrame(_rafId)
    _rafId = null
  }
}

// == Expose public API ==
window.AmllBridge = {
  init: initLyricPlayer,
  setLyricLines: setLyricLines,
  setCurrentTime: setCurrentTime,
  setPlaying: setPlaying,
  setConfig: setConfig,
  dispose: dispose,
  startAnimation: _startAnimationLoop,
  stopAnimation: _stopAnimationLoop,
}

// Auto-start animation when bridge is ready
document.addEventListener('DOMContentLoaded', function () {
  _startAnimationLoop()
})
