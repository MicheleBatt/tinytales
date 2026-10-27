import { Controller } from "@hotwired/stimulus"

// Anteprima a tutto schermo di immagini e video.
// Basta segnare un elemento con data-lightbox="indirizzo del file" (più, facoltativi,
// data-lightbox-type="image|video", data-lightbox-group e data-lightbox-caption):
// il clic viene intercettato qui, anche per gli elementi creati dopo (chat, anteprime dei nuovi file).
// Si chiude con ×, Esc o clic fuori; con più file nello stesso gruppo, ← → scorrono.
export default class extends Controller {
  open(event) {
    const trigger = event.target.closest("[data-lightbox]")
    if (!trigger || !this.element.contains(trigger)) return

    event.preventDefault()
    event.stopPropagation()
    const group = trigger.dataset.lightboxGroup
    this.items = group ? [...this.element.querySelectorAll(`[data-lightbox][data-lightbox-group="${CSS.escape(group)}"]`)] : [trigger]
    this.index = Math.max(0, this.items.indexOf(trigger))
    this.trigger = trigger
    this.dialog().showModal()
    this.show()
  }

  dialog() {
    if (this.box) return this.box

    const box = document.createElement("dialog")
    box.className = "lightbox"
    box.setAttribute("aria-label", "Anteprima")
    box.innerHTML = `
      <button type="button" class="lightbox-chiudi" aria-label="Chiudi l'anteprima">×</button>
      <button type="button" class="lightbox-freccia lightbox-prima" aria-label="File precedente">‹</button>
      <figure class="lightbox-figura"><div class="lightbox-media"></div><figcaption></figcaption></figure>
      <button type="button" class="lightbox-freccia lightbox-dopo" aria-label="File successivo">›</button>`
    box.querySelector(".lightbox-chiudi").addEventListener("click", () => box.close())
    box.querySelector(".lightbox-prima").addEventListener("click", () => this.step(-1))
    box.querySelector(".lightbox-dopo").addEventListener("click", () => this.step(1))
    // Clic sullo sfondo scuro (fuori da immagine e pulsanti): chiude.
    box.addEventListener("click", (e) => { if (e.target === box || e.target.classList.contains("lightbox-figura")) box.close() })
    box.addEventListener("keydown", (e) => {
      if (e.key === "ArrowLeft") { e.preventDefault(); this.step(-1) }
      if (e.key === "ArrowRight") { e.preventDefault(); this.step(1) }
    })
    box.addEventListener("close", () => {
      box.querySelector(".lightbox-media").replaceChildren()
      this.trigger?.focus?.()
    })
    document.body.append(box)
    return (this.box = box)
  }

  step(delta) {
    if (this.items.length < 2) return
    this.index = (this.index + delta + this.items.length) % this.items.length
    this.show()
  }

  show() {
    const item = this.items[this.index]
    const src = item.dataset.lightbox
    const caption = item.dataset.lightboxCaption || src.split("/").pop().split("?")[0]
    const isVideo = item.dataset.lightboxType === "video" || /\.(mp4|mov|m4v|webm)(\?|$)/i.test(caption)

    let media
    if (isVideo) {
      media = document.createElement("video")
      media.controls = true
      media.autoplay = true
      media.playsInline = true
    } else {
      media = document.createElement("img")
      media.alt = caption
    }
    media.src = src
    this.box.querySelector(".lightbox-media").replaceChildren(media)

    const counter = this.items.length > 1 ? ` · ${this.index + 1} di ${this.items.length}` : ""
    this.box.querySelector("figcaption").textContent = caption + counter
    this.box.querySelectorAll(".lightbox-freccia").forEach((b) => { b.hidden = this.items.length < 2 })
    this.box.querySelector(".lightbox-chiudi").focus()
  }
}
