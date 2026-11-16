import { Controller } from "@hotwired/stimulus"

// Gestisce i file del post nel form: ordine (trascinamento o frecce), rimozione e aggiunta di file nuovi.
// L'ordine inviato è quello dei campi nascosti nella pagina, quindi basta spostare le miniature.
//
// Un file nuovo (scelto dal computer o approvato nella chat di Claude) diventa una miniatura come le altre:
// porta con sé il suo campo file (post[new_media][codice]) e, nell'elenco ordinato, il segnaposto «nuovo:codice»,
// che il server sostituisce con il file. Così anche i nuovi si spostano, si tolgono e si guardano a tutto schermo.
let counter = 0

export default class extends Controller {
  static targets = ["list", "item", "keep", "position", "input", "hint"]

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
    if (this.hasHintTarget) this.hintTarget.hidden = this.itemTargets.length === 0
  }

  itemFor(event) {
    return event.currentTarget.closest("[data-media-editor-target='item']")
  }

  // ---------- rimozione ----------

  // Un file da togliere non viene più inviato (né fra quelli da tenere né, se è nuovo, come file). Si può annullare.
  toggle(event) {
    const item = this.itemFor(event)
    const keep = item.querySelector("[data-media-editor-target='keep']")
    keep.disabled = !keep.disabled
    item.querySelectorAll("input[type=file]").forEach((input) => { input.disabled = keep.disabled })
    item.classList.toggle("da-rimuovere", keep.disabled)
    event.currentTarget.textContent = keep.disabled ? "Annulla rimozione" : "Rimuovi"
    this.renumber()
  }

  // ---------- nuovi file ----------

  // I file scelti dal computer: ognuno diventa una miniatura in fondo alla galleria; il campo si svuota.
  addChosen() {
    ;[...this.inputTarget.files].forEach((file) => this.addFile(file))
    this.inputTarget.value = ""
  }

  // Aggiunge un file nuovo in fondo alla galleria e restituisce la sua miniatura (la usa anche la chat di Claude).
  addFile(file) {
    const code = `${Date.now().toString(36)}${(counter += 1)}`
    const url = URL.createObjectURL(file)
    const isVideo = file.type.startsWith("video/") || /\.(mp4|mov|m4v|webm)$/i.test(file.name)
    const lightbox = { lightbox: url, lightboxGroup: "post-media", lightboxCaption: file.name,
                       lightboxType: isVideo ? "video" : "image", lightboxDownload: url }

    const figure = document.createElement("figure")
    figure.draggable = true
    figure.dataset.mediaEditorTarget = "item"
    figure.dataset.action = "dragstart->media-editor#dragStart dragend->media-editor#dragEnd"
    figure.dataset.nuovo = ""

    const position = Object.assign(document.createElement("span"), { className: "posizione" })
    position.dataset.mediaEditorTarget = "position"
    figure.append(position)

    if (isVideo) {
      const video = Object.assign(document.createElement("video"), { src: url, controls: true, preload: "metadata" })
      const open = Object.assign(document.createElement("button"), { type: "button", className: "lightbox-apri", textContent: "⤢",
                                                                     title: "Guarda a tutto schermo" })
      open.setAttribute("aria-label", `Guarda ${file.name} a tutto schermo`)
      Object.assign(open.dataset, lightbox)
      figure.append(video, open)
    } else {
      const img = Object.assign(document.createElement("img"), { src: url, alt: file.name, draggable: false,
                                                                 className: "apribile", title: "Clic per vederla a tutto schermo" })
      Object.assign(img.dataset, lightbox)
      figure.append(img)
    }

    const keep = Object.assign(document.createElement("input"), { type: "hidden", name: "post[media][]", value: `nuovo:${code}` })
    keep.dataset.mediaEditorTarget = "keep"
    const upload = Object.assign(document.createElement("input"), { type: "file", name: `post[new_media][${code}]`, hidden: true })
    const transfer = new DataTransfer()
    transfer.items.add(file)
    upload.files = transfer.files
    figure.append(keep, upload)

    const caption = document.createElement("figcaption")
    caption.append(Object.assign(document.createElement("span"), { textContent: file.name }))
    const commands = Object.assign(document.createElement("span"), { className: "comandi" })
    const button = (text, action, className, label) => {
      const b = Object.assign(document.createElement("button"), { type: "button", className, textContent: text })
      b.dataset.action = action
      if (label) b.setAttribute("aria-label", label)
      return b
    }
    commands.append(button("←", "media-editor#moveEarlier", "bottone-freccia", `Sposta ${file.name} prima`),
                    button("→", "media-editor#moveLater", "bottone-freccia", `Sposta ${file.name} dopo`),
                    button("Rimuovi", "media-editor#toggle", "bottone-piccolo"))
    caption.append(commands)
    figure.append(caption)

    this.listTarget.append(figure)
    this.renumber()
    return figure
  }
}
