export const EpgGuide = {
  mounted() {
    this.scrollEl = this.el.querySelector(".tv-epg-scroll")
    this.handleEvent("epg_scroll_to", ({ offset }) => this.scrollToOffset(offset))
    this.scrollToNow()
  },

  updated() {
    // Keep "now" in view after day reloads when still today
    if (this.el.dataset.nowOffset && !this._scrolledOnce) {
      this.scrollToNow()
    }
  },

  scrollToNow() {
    const raw = this.el.dataset.nowOffset
    if (raw === undefined || raw === "") return
    const offset = Number(raw)
    if (!Number.isFinite(offset)) return
    this.scrollToOffset(offset)
    this._scrolledOnce = true
  },

  scrollToOffset(offset) {
    if (!this.scrollEl) return
    const channelCol = this.el.querySelector(".tv-epg-corner")
    const gutter = channelCol ? channelCol.offsetWidth : 0
    const target = Math.max(offset - this.scrollEl.clientWidth / 3 + gutter, 0)
    this.scrollEl.scrollTo({ left: target, behavior: "smooth" })
  }
}
