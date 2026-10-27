import { Controller } from "@hotwired/stimulus"

// Anteprima a tutto schermo di immagini e video.
// Basta segnare un elemento con data-lightbox="indirizzo del file" (più, facoltativi,
// data-lightbox-type="image|video", data-lightbox-group e data-lightbox-caption):
// il clic viene intercettato qui, anche per gli elementi creati dopo (chat, anteprime dei nuovi file).
// Si chiude con ×, Esc o clic fuori; con più file nello stesso gruppo, ← → scorrono.
//
// Ogni anteprima riceve anche un'iconcina ⤓ nell'angolo in alto a destra per scaricare il file
// (indirizzo in data-lightbox-download, altrimenti quello dell'anteprima). Anche questa viene aggiunta
// da sola agli elementi creati dopo; il clic sull'iconcina scarica e non apre l'anteprima.
export default class extends Controller {
  connect() {
    this.decorate()
    this.observer = new MutationObserver(() => {
      clearTimeout(this.pending)
      this.pending = setTimeout(() => this.decorate(), 0)
    })
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer?.disconnect()
    clearTimeout(this.pending)
  }

  open(event) {
    const download = event.target.closest(".scarica")
    if (download && this.element.contains(download)) {
      event.preventDefault()
      event.stopPropagation()
      this.download(download)
      return
    }

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

  // Aggiunge l'iconcina di download alle anteprime che non ce l'hanno ancora.
  // - pulsante ⤢ dei video: l'iconcina va accanto, nell'angolo, e il ⤢ si sposta un po' a sinistra;
  // - immagine o video «nudi»: vengono avvolti in un contenitore che fa da riferimento per l'angolo;
  // - contenitori (link, riquadri): l'iconcina va dentro.
  decorate() {
    this.element.querySelectorAll("[data-lightbox]:not([data-scaricabile])").forEach((trigger) => {
      if (trigger.hidden || trigger.closest(".lightbox")) return
      if (trigger.dataset.lightboxScarica === "no") return // miniature troppo piccole (elenco dei post)
      trigger.dataset.scaricabile = ""
      const button = this.downloadButton(trigger)

      if (trigger.tagName === "BUTTON") {
        trigger.classList.add("con-scarica")
        trigger.before(button)
      } else if (["IMG", "VIDEO"].includes(trigger.tagName)) {
        const frame = document.createElement("span")
        frame.className = "scaricabile"
        trigger.before(frame)
        frame.append(trigger, button)
      } else {
        trigger.classList.add("scaricabile")
        trigger.append(button)
      }
    })
  }

  downloadButton(trigger) {
    const name = trigger.dataset.lightboxCaption || ""
    const button = document.createElement("button")
    button.type = "button"
    button.className = "scarica"
    button.title = name ? `Scarica ${name}` : "Scarica il file"
    button.setAttribute("aria-label", button.title)
    button.innerHTML = `<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M8 2v8m0 0L4.8 6.8M8 10l3.2-3.2M3 13.5h10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>`
    button.lightboxTrigger = trigger
    return button
  }

  // Scarica con un link temporaneo: funziona anche per i file appena scelti, non ancora caricati (blob:).
  download(button) {
    const trigger = button.lightboxTrigger || button.parentElement.querySelector("[data-lightbox]")
    if (!trigger) return

    const link = document.createElement("a")
    link.href = trigger.dataset.lightboxDownload || trigger.dataset.lightbox
    link.download = trigger.dataset.lightboxCaption || ""
    link.hidden = true
    document.body.append(link)
    link.click()
    link.remove()
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
