const SKIP_SECONDS = 10

function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00"

  const total = Math.floor(seconds)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const mm = h > 0 ? String(m).padStart(2, "0") : String(m)
  const ss = String(s).padStart(2, "0")

  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`
}

export const RecordingPlayer = {
  mounted() {
    this.video = this.el.querySelector("video")
    this.hideTimer = null
    this.seeking = false
    this.boundKeydown = (e) => this.onKeydown(e)

    this.ui = this.el.querySelector("[data-player-ui]")
    this.chrome = this.el.querySelector("[data-chrome]")
    this.topChrome = this.el.querySelector("[data-top-chrome]")
    this.bigPlay = this.el.querySelector("[data-big-play]")
    this.playPauseBtn = this.el.querySelector("[data-play-pause]")
    this.skipBackBtn = this.el.querySelector("[data-skip-back]")
    this.skipForwardBtn = this.el.querySelector("[data-skip-forward]")
    this.muteBtn = this.el.querySelector("[data-mute]")
    this.volumeSlider = this.el.querySelector("[data-volume]")
    this.fullscreenBtn = this.el.querySelector("[data-fullscreen]")
    this.seekSlider = this.el.querySelector("[data-seek]")
    this.currentTimeEl = this.el.querySelector("[data-current-time]")
    this.durationEl = this.el.querySelector("[data-duration]")
    this.iconPlay = this.el.querySelector("[data-icon-play]")
    this.iconPause = this.el.querySelector("[data-icon-pause]")
    this.iconUnmuted = this.el.querySelector("[data-icon-unmuted]")
    this.iconMuted = this.el.querySelector("[data-icon-muted]")
    this.iconFsEnter = this.el.querySelector("[data-icon-fs-enter]")
    this.iconFsExit = this.el.querySelector("[data-icon-fs-exit]")
    this.stage = this.el

    this.bindControls()
    this.tryPlay()
    this.syncUi()
    this.syncProgress()
    this.el.focus({ preventScroll: true })
  },

  updated() {},

  destroyed() {
    this.clearHideTimer()
    document.removeEventListener("keydown", this.boundKeydown)
    document.removeEventListener("fullscreenchange", this.boundFullscreen)
  },

  bindControls() {
    this.boundFullscreen = () => this.syncFullscreenUi()

    this.playPauseBtn?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.togglePlay()
    })

    this.bigPlay?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.video.muted = false
      this.play()
    })

    this.skipBackBtn?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.skip(-SKIP_SECONDS)
    })

    this.skipForwardBtn?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.skip(SKIP_SECONDS)
    })

    this.muteBtn?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.video.muted = !this.video.muted
      if (!this.video.muted && this.video.volume === 0) {
        this.video.volume = 0.5
        if (this.volumeSlider) this.volumeSlider.value = "0.5"
      }
      this.syncMuteUi()
      this.revealChrome()
    })

    this.volumeSlider?.addEventListener("input", (e) => {
      e.stopPropagation()
      const value = Number(e.target.value)
      this.video.volume = value
      this.video.muted = value === 0
      this.syncMuteUi()
      this.revealChrome()
    })

    this.fullscreenBtn?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.toggleFullscreen()
    })

    this.seekSlider?.addEventListener("pointerdown", (e) => {
      e.stopPropagation()
      this.seeking = true
      this.revealChrome(true)
    })

    this.seekSlider?.addEventListener("input", (e) => {
      e.stopPropagation()
      const ratio = Number(e.target.value)
      const duration = this.video.duration
      if (!Number.isFinite(duration) || duration <= 0) return

      const time = ratio * duration
      if (this.currentTimeEl) this.currentTimeEl.textContent = formatTime(time)
      this.seekSlider.style.setProperty("--tv-seek", `${ratio * 100}%`)
      this.revealChrome(true)
    })

    const commitSeek = (e) => {
      e.stopPropagation()
      const ratio = Number(e.target.value)
      const duration = this.video.duration
      this.seeking = false

      if (Number.isFinite(duration) && duration > 0) {
        this.video.currentTime = ratio * duration
      }

      this.syncProgress()
      this.revealChrome()
    }

    this.seekSlider?.addEventListener("change", commitSeek)
    this.seekSlider?.addEventListener("pointerup", commitSeek)

    this.closeBtn = this.el.querySelector("[data-close]")
    this.closeBtn?.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.pushEvent("close_player", {})
    })

    // Keep chrome clicks from toggling play/pause on the stage.
    this.chrome?.addEventListener("click", (e) => e.stopPropagation())
    this.topChrome?.addEventListener("click", (e) => e.stopPropagation())

    this.el.addEventListener("click", (e) => {
      if (e.target.closest("[data-player-ui] button, [data-player-ui] input, a")) return
      this.togglePlay()
    })

    this.el.addEventListener("mousemove", () => this.revealChrome())
    this.el.addEventListener("mouseleave", () => this.scheduleHideChrome())
    this.el.addEventListener("focusin", () => this.revealChrome())
    this.el.addEventListener("focusout", () => this.scheduleHideChrome())
    this.el.addEventListener("touchstart", () => this.revealChrome(), { passive: true })

    this.video.addEventListener("play", () => this.syncUi())
    this.video.addEventListener("pause", () => this.syncUi())
    this.video.addEventListener("ended", () => this.syncUi())
    this.video.addEventListener("volumechange", () => this.syncMuteUi())
    this.video.addEventListener("timeupdate", () => this.syncProgress())
    this.video.addEventListener("loadedmetadata", () => this.syncProgress())
    this.video.addEventListener("durationchange", () => this.syncProgress())
    this.video.addEventListener("seeking", () => this.syncProgress())

    document.addEventListener("fullscreenchange", this.boundFullscreen)
    document.addEventListener("keydown", this.boundKeydown)
  },

  onKeydown(e) {
    if (!this.keyboardActive()) return

    const key = e.key.toLowerCase()
    if (key === " " || key === "k") {
      e.preventDefault()
      this.togglePlay()
    } else if (key === "m") {
      e.preventDefault()
      this.video.muted = !this.video.muted
      this.syncMuteUi()
      this.revealChrome()
    } else if (key === "f") {
      e.preventDefault()
      this.toggleFullscreen()
    } else if (key === "arrowleft" || key === "j") {
      e.preventDefault()
      this.skip(-SKIP_SECONDS)
    } else if (key === "arrowright" || key === "l") {
      e.preventDefault()
      this.skip(SKIP_SECONDS)
    }
  },

  keyboardActive() {
    if (document.fullscreenElement === this.stage) return true
    const active = document.activeElement
    return active instanceof Element && this.el.contains(active)
  },

  tryPlay() {
    const playPromise = this.video.play()
    if (playPromise && typeof playPromise.then === "function") {
      playPromise
        .then(() => {
          if (this.bigPlay) this.bigPlay.hidden = true
          this.syncUi()
        })
        .catch(() => {
          if (this.bigPlay) this.bigPlay.hidden = false
          this.syncUi()
        })
    }
  },

  play() {
    const playPromise = this.video.play()
    if (playPromise && typeof playPromise.then === "function") {
      playPromise
        .then(() => {
          if (this.bigPlay) this.bigPlay.hidden = true
          this.syncUi()
        })
        .catch(() => {
          if (this.bigPlay) this.bigPlay.hidden = false
          this.syncUi()
        })
    }
  },

  togglePlay() {
    if (this.video.paused || this.video.ended) {
      this.play()
    } else {
      this.video.pause()
      this.syncUi()
    }
  },

  skip(delta) {
    const duration = this.video.duration
    if (!Number.isFinite(duration)) return

    const next = Math.min(Math.max(this.video.currentTime + delta, 0), duration)
    this.video.currentTime = next
    this.syncProgress()
    this.revealChrome()
  },

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen?.()
    } else {
      this.stage.requestFullscreen?.()
    }
  },

  syncProgress() {
    const duration = this.video.duration
    const current = this.video.currentTime
    const hasDuration = Number.isFinite(duration) && duration > 0
    const ratio = hasDuration ? Math.min(Math.max(current / duration, 0), 1) : 0

    if (this.durationEl) {
      this.durationEl.textContent = hasDuration ? formatTime(duration) : "0:00"
    }

    if (!this.seeking) {
      if (this.currentTimeEl) this.currentTimeEl.textContent = formatTime(current)
      if (this.seekSlider) {
        this.seekSlider.value = String(ratio)
        this.seekSlider.style.setProperty("--tv-seek", `${ratio * 100}%`)
        this.seekSlider.disabled = !hasDuration
      }
    }
  },

  syncUi() {
    const playing = !this.video.paused && !this.video.ended

    if (this.iconPlay) this.iconPlay.hidden = playing
    if (this.iconPause) this.iconPause.hidden = !playing

    if (this.playPauseBtn) {
      this.playPauseBtn.setAttribute("aria-label", playing ? "Pausieren" : "Abspielen")
    }

    if (this.bigPlay) this.bigPlay.hidden = playing

    this.el.classList.toggle("is-playing", playing)
    this.el.classList.toggle("is-paused", !playing)

    this.syncMuteUi()
    this.syncFullscreenUi()
    this.syncProgress()

    if (playing) {
      this.revealChrome()
    } else {
      this.clearHideTimer()
      this.setChromeVisible(true)
    }
  },

  syncMuteUi() {
    const muted = this.video.muted || this.video.volume === 0
    const shownVolume = muted ? 0 : this.video.volume
    if (this.iconUnmuted) this.iconUnmuted.hidden = muted
    if (this.iconMuted) this.iconMuted.hidden = !muted
    if (this.muteBtn) {
      this.muteBtn.setAttribute("aria-label", muted ? "Ton an" : "Stummschalten")
    }
    if (this.volumeSlider) {
      if (document.activeElement !== this.volumeSlider) {
        this.volumeSlider.value = String(shownVolume)
      }
      this.volumeSlider.style.setProperty("--tv-volume", `${shownVolume * 100}%`)
    }
  },

  syncFullscreenUi() {
    const active = document.fullscreenElement === this.stage
    if (this.iconFsEnter) this.iconFsEnter.hidden = active
    if (this.iconFsExit) this.iconFsExit.hidden = !active
    if (this.fullscreenBtn) {
      this.fullscreenBtn.setAttribute("aria-label", active ? "Vollbild beenden" : "Vollbild")
    }
  },

  setChromeVisible(visible) {
    this.chrome?.classList.toggle("is-visible", visible)
    this.topChrome?.classList.toggle("is-visible", visible)
  },

  revealChrome(sticky = false) {
    this.setChromeVisible(true)
    if (sticky) {
      this.clearHideTimer()
      return
    }
    this.scheduleHideChrome()
  },

  scheduleHideChrome() {
    this.clearHideTimer()
    if (this.video.paused || this.video.ended || this.seeking) return
    if (this.el.contains(document.activeElement)) return

    this.hideTimer = window.setTimeout(() => {
      if (!this.video.paused && !this.seeking) this.setChromeVisible(false)
    }, 2500)
  },

  clearHideTimer() {
    if (this.hideTimer) {
      window.clearTimeout(this.hideTimer)
      this.hideTimer = null
    }
  }
}
