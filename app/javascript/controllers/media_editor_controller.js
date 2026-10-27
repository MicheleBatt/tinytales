import { Controller } from "@hotwired/stimulus"

// Gestisce i file del post nel form: ordine (trascinamento o frecce), rimozione e anteprima dei nuovi.
// L'ordine inviato è quello dei campi nascosti nella pagina, quindi basta spostare le miniature.
export default class extends Controller {
  static targets = ["list", "item", "keep", "position", "input", "previews"]

  connect() {
    this.renumber()
  }

  // ---------- ordine ----------

  dragStart(event) {
    this.dragged = event.currentTarget
    this.dragged.classList.add("in-trascinamento")
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", "")
  }

  dragOver(event) {
    if (!this.dragged) return
    event.preventDefault()
    const target = event.target.closest("[data-media-editor-target='item']")
    if (!target || target === this.dragged) return

    const box = target.getBoundingClientRect()
    const after = event.clientX > box.left + box.width / 2
    target.parentNode.insertBefore(this.dragged, after ? target.nextSibling : target)
  }

  drop(event) {
    event.preventDefault()
  }

  dragEnd() {
    this.dragged?.classList.remove("in-trascinamento")
    this.dragged = null
    this.renumber()
  }

  moveEarlier(event) {
    const item = this.itemFor(event)
    const previous = item.previousElementSibling
    if (previous) {
      item.parentNode.insertBefore(item, previous)
      this.afterMove(event)
    }
  }

  moveLater(event) {
    const item = this.itemFor(event)
    const next = item.nextElementSibling
    if (next) {
      item.parentNode.insertBefore(next, item)
      this.afterMove(event)
    }
  }

  afterMove(event) {
    this.renumber()
    event.currentTarget.focus()
  }

  // I numeri contano solo i file che restano: quelli da rimuovere non hanno numero.
  renumber() {
    let n = 0
    this.itemTargets.forEach((item) => {
      const keep = item.querySelector("[data-media-editor-target='keep']")
      const position = item.querySelector("[data-media-editor-target='position']")
      position.textContent = keep.disabled ? "–" : String(++n)
    })
  }

  itemFor(event) {
    return event.currentTarget.closest("[data-media-editor-target='item']")
  }

  // ---------- rimozione ----------

  // Un file da togliere non viene più inviato fra quelli da tenere. Si può annullare.
  toggle(event) {
    const item = this.itemFor(event)
    const keep = item.querySelector("[data-media-editor-target='keep']")
    keep.disabled = !keep.disabled
    item.classList.toggle("da-rimuovere", keep.disabled)
    event.currentTarget.textContent = keep.disabled ? "Annulla rimozione" : "Rimuovi"
    this.renumber()
  }

  // ---------- nuovi file ----------

  preview() {
    this.previewsTarget.replaceChildren()
    for (const file of this.inputTarget.files) {
      const figure = document.createElement("figure")
      figure.className = "nuovo"
      const url = URL.createObjectURL(file)
      const isImage = file.type.startsWith("image/")
      let preview
      if (isImage) {
        preview = document.createElement("img")
        preview.src = url
        preview.alt = file.name
      } else {
        preview = document.createElement("div")
        preview.className = "segnaposto-video"
        preview.textContent = "▶ video"
      }
      // Clic: anteprima a tutto schermo (controller lightbox sul body).
      Object.assign(preview.dataset, { lightbox: url, lightboxGroup: "nuovi-file", lightboxCaption: file.name,
                                       lightboxType: isImage ? "image" : "video" })
      preview.classList.add("apribile")
      preview.title = "Clic per vederlo a tutto schermo"
      figure.append(preview)
      const caption = document.createElement("figcaption")
      caption.textContent = `${file.name} · da caricare, andrà in fondo`
      figure.append(caption)
      this.previewsTarget.append(figure)
    }
  }
}
