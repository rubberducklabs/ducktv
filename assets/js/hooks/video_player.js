import Hls from "../../vendor/hls.js"

export const VideoPlayer = {
  mounted() {
    this.video = this.el.querySelector("video")
    this.hls = null
    this.hideTimer = null
    this.status = "idle"
    this.boundKeydown = (e) => this.onKeydown(e)

    this.ui = this.el.querySelector("[data-player-ui]")
    this.chrome = this.el.querySelector("[data-chrome]")
    this.bigPlay = this.el.querySelector("[data-big-play]")
    this.playPauseBtn = this.el.querySelector("[data-play-pause]")
    this.muteBtn = this.el.querySelector("[data-mute]")
    this.volumeSlider = this.el.querySelector("[data-volume]")
    this.fullscreenBtn = this.el.querySelector("[data-fullscreen]")
    this.iconPlay = this.el.querySelector("[data-icon-play]")
    this.iconPause = this.el.querySelector("[data-icon-pause]")
    this.iconUnmuted = this.el.querySelector("[data-icon-unmuted]")
    this.iconMuted = this.el.querySelector("[data-icon-muted]")
    this.iconFsEnter = this.el.querySelector("[data-icon-fs-enter]")
    this.iconFsExit = this.el.querySelector("[data-icon-fs-exit]")
    this.stage = this.el.closest(".tv-player-stage") || this.el

    // Stream URL/status arrive via push_event so LiveView DOM patches
    // (EPG, encoder dots, filter, etc.) never touch playback.
    this.handleEvent("stream_state", ({ status, playlist_url }) => {
      this.applyStreamState(status, playlist_url)
    })

    this.bindControls()
    this.syncUi()
  },

  // phx-update="ignore" still merges data-* and can invoke updated();
  // never reload media from DOM patches.
  updated() {},

  destroyed() {
    this.clearHideTimer()
    document.removeEventListener("keydown", this.boundKeydown)
    this.destroyPlayer()
  },

  bindControls() {
    this.playPauseBtn?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.togglePlay()
    })

    this.bigPlay?.addEventListener("click", (e) => {
      e.stopPropagation()
      this.video.muted = false
      this.play()
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

    this.chrome?.addEventListener("click", (e) => e.stopPropagation())

    this.el.addEventListener("click", () => {
      if (!this.isReady()) return
      this.togglePlay()
    })

    this.el.addEventListener("mousemove", () => this.revealChrome())
    this.el.addEventListener("mouseleave", () => this.scheduleHideChrome())
    this.el.addEventListener("focusin", () => this.revealChrome())
    this.el.addEventListener("focusout", () => this.scheduleHideChrome())

    this.video.addEventListener("play", () => this.syncUi())
    this.video.addEventListener("pause", () => this.syncUi())
    this.video.addEventListener("volumechange", () => this.syncMuteUi())

    document.addEventListener("fullscreenchange", () => this.syncFullscreenUi())
    document.addEventListener("keydown", this.boundKeydown)
  },

  onKeydown(e) {
    if (!this.isReady() || !this.keyboardActive()) return

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
    }
  },

  keyboardActive() {
    if (document.fullscreenElement === this.stage) return true
    const active = document.activeElement
    return active instanceof Element && this.el.contains(active)
  },

  isReady() {
    return this.status === "ready"
  },

  applyStreamState(status, url) {
    this.status = status || "idle"

    if (this.ui) this.ui.hidden = this.status !== "ready"

    if (this.status !== "ready" || !url) {
      if (this.status !== "ready") this.destroyPlayer()
      this.syncUi()
      return
    }

    if (this.currentUrl === url && this.hls) return

    this.destroyPlayer()
    this.currentUrl = url
    this.attachSource(url)
  },

  attachSource(url) {
    const video = this.video

    if (Hls.isSupported()) {
      this.hls = new Hls({
        enableWorker: true,
        lowLatencyMode: false,
        // Sit ~2 finished segments behind live (matches playlist_ready
        // waiting for 2 segments). Stream-copy remux segments follow the
        // source GOP (often 5–15s), so keep buffer/timeouts generous.
        liveSyncDurationCount: 2,
        liveMaxLatencyDurationCount: 8,
        maxLiveSyncPlaybackRate: 1,
        maxBufferLength: 60,
        maxMaxBufferLength: 120,
        manifestLoadingTimeOut: 15000,
        levelLoadingTimeOut: 15000,
        fragLoadingTimeOut: 30000,
        fragLoadingMaxRetry: 6
      })
      this.hls.loadSource(url)
      this.hls.attachMedia(video)

      this.startedBehind = false
      this.hls.on(Hls.Events.LEVEL_LOADED, (_event, data) => {
        if (this.startedBehind || !data.details?.live) return

        const frags = data.details.fragments || []
        if (frags.length <= 2) return

        const target = frags[frags.length - 2]
        if (target && Number.isFinite(target.start)) {
          this.startedBehind = true
          this.hls.startLoad(target.start)
        }
      })
      this.hls.on(Hls.Events.MANIFEST_PARSED, () => this.tryPlay())
      this.hls.on(Hls.Events.ERROR, (_event, data) => {
        if (!data.fatal) return

        if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
          // Stale segment after window slide — jump back to a safe live position.
          if (data.details === Hls.ErrorDetails.FRAG_LOAD_ERROR ||
            data.details === Hls.ErrorDetails.FRAG_LOAD_TIMEOUT) {
            this.hls.stopLoad()
            this.hls.startLoad(-1)
          } else {
            this.hls.startLoad()
          }
        } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
          this.hls.recoverMediaError()
        }
      })
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
      video.src = url
      video.addEventListener("loadedmetadata", () => this.tryPlay(), { once: true })
    }
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
    if (this.video.paused) {
      this.play()
    } else {
      this.video.pause()
      this.syncUi()
    }
  },

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen?.()
    } else {
      this.stage.requestFullscreen?.()
    }
  },

  syncUi() {
    const playing = !this.video.paused && !this.video.ended
    const ready = this.isReady()

    if (this.iconPlay) this.iconPlay.hidden = playing
    if (this.iconPause) this.iconPause.hidden = !playing

    if (this.playPauseBtn) {
      this.playPauseBtn.setAttribute("aria-label", playing ? "Pausieren" : "Abspielen")
    }

    if (this.el) {
      this.el.classList.toggle("is-playing", playing && ready)
      this.el.classList.toggle("is-paused", !playing && ready)
    }

    this.syncMuteUi()
    this.syncFullscreenUi()

    if (!ready) {
      this.clearHideTimer()
      this.chrome?.classList.remove("is-visible")
      return
    }

    if (playing) {
      this.revealChrome()
    } else {
      this.clearHideTimer()
      this.chrome?.classList.add("is-visible")
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

  revealChrome() {
    if (!this.isReady()) return
    this.chrome?.classList.add("is-visible")
    this.scheduleHideChrome()
  },

  scheduleHideChrome() {
    this.clearHideTimer()
    if (!this.isReady() || this.video.paused) return
    if (this.el.contains(document.activeElement)) return

    this.hideTimer = window.setTimeout(() => {
      if (!this.video.paused) this.chrome?.classList.remove("is-visible")
    }, 2500)
  },

  clearHideTimer() {
    if (this.hideTimer) {
      window.clearTimeout(this.hideTimer)
      this.hideTimer = null
    }
  },

  destroyPlayer() {
    if (this.hls) {
      this.hls.destroy()
      this.hls = null
    }
    if (this.video) {
      this.video.removeAttribute("src")
      this.video.load()
    }
    this.currentUrl = null
    if (this.bigPlay) this.bigPlay.hidden = true
  }
}
