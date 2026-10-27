import { Controller } from "@hotwired/stimulus"

// La chat con l'assistente (Claude Code) nelle pagine di creazione e modifica di un post.
// Manda il messaggio insieme allo stato attuale del form, mostra la risposta mentre arriva
// e trasforma i blocchi ```proposta:…``` in riquadri con il pulsante «Applica al form».
const FIELDS = {
  titolo: { label: "Titolo", selector: "[name='post[title]']" },
  testo: { label: "Testo del post", selector: "[name='post[body]']" },
  note: { label: "Note", selector: "[name='post[notes]']" },
  data: { label: "Data e ora", selector: "[name='post[publish_at]']" },
  file: { label: "Immagine o video" }
}
const OPEN_KEY = "assistente-aperto"
const REDUCED_MOTION = window.matchMedia("(prefers-reduced-motion: reduce)")
const MAX_FILES = 10
const MAX_FILE_SIZE = 100 * 1024 * 1024

function humanSize(bytes) {
  if (bytes < 1024) return `${bytes} byte`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1).replace(".", ",")} MB`
}

// Fa comparire il testo una lettera alla volta, come se qualcuno lo stesse battendo.
// Va a circa 45 caratteri al secondo; se Claude scrive più in fretta, accelera
// quanto basta per non restare indietro più di un paio di secondi.
class Typewriter {
  static BASE_SPEED = 45
  static MAX_LAG_SECONDS = 2.5

  constructor(render) {
    this.render = render
    this.target = ""
    this.shown = 0
    this.carry = 0
    this.last = 0
    this.frame = null
    this.waiting = []
  }

  // Un timer normale e non requestAnimationFrame: così il testo avanza anche se la scheda
  // è in secondo piano (più lentamente), invece di fermarsi e lasciare la chat bloccata.
  push(text) {
    this.target += text
    if (REDUCED_MOTION.matches) return this.flush()
    this.frame ??= setTimeout(() => this.tick(performance.now()), 16)
  }

  tick(time) {
    this.frame = null
    const elapsed = this.last ? Math.min(time - this.last, 1000) : 16
    this.last = time
    const backlog = this.target.length - this.shown
    if (backlog <= 0) return this.idle()

    const speed = Math.max(Typewriter.BASE_SPEED, backlog / Typewriter.MAX_LAG_SECONDS)
    this.carry += (speed * elapsed) / 1000
    const step = Math.floor(this.carry)
    if (step > 0) {
      this.carry -= step
      this.shown = Math.min(this.target.length, this.shown + step)
      // Non spezzare un'emoji a metà: una coppia surrogata va mostrata intera.
      const code = this.target.charCodeAt(this.shown - 1)
      if (code >= 0xd800 && code <= 0xdbff) this.shown += 1
      this.render(this.target.slice(0, this.shown), true)
    }
    this.frame = setTimeout(() => this.tick(performance.now()), 16)
  }

  idle() {
    this.last = 0
    this.render(this.target, false)
    this.waiting.splice(0).forEach((resolve) => resolve())
  }

  // Si risolve quando tutto il testo arrivato è stato mostrato.
  finished() {
    if (this.shown >= this.target.length) return Promise.resolve()
    return new Promise((resolve) => this.waiting.push(resolve))
  }

  flush() {
    this.shown = this.target.length
    this.idle()
  }

  stop() {
    if (this.frame) clearTimeout(this.frame)
    this.frame = null
    this.waiting.splice(0).forEach((resolve) => resolve())
  }
}

// La stessa idea per le righe brevi di attività («Leggo…», «Eseguo…»).
function typeInto(element, text, onDone = () => {}) {
  if (REDUCED_MOTION.matches) { element.textContent = text; onDone(); return }
  let i = 0
  const timer = setInterval(() => {
    i = Math.min(text.length, i + 2)
    element.textContent = text.slice(0, i)
    if (i >= text.length) { clearInterval(timer); onDone() }
  }, 16)
}

export default class extends Controller {
  static targets = ["panel", "opener", "messages", "intro", "stored", "input", "send", "stop", "status",
                    "pending", "fileInput", "attach"]
  static values = { url: String, token: String, postId: String, fileUrl: String }

  connect() {
    this.idlePlaceholder = this.inputTarget.placeholder
    this.pendingFiles = []
    this.storedTargets.forEach((el) => {
      this.renderInto(el.querySelector(".msg-corpo"), el.dataset.raw, el.classList.contains("msg-assistant"))
      const attachments = JSON.parse(el.dataset.attachments || "[]")
      if (attachments.length) el.append(this.attachmentList(attachments.map((a) => ({ name: a.original || a.name, url: this.fileUrl(a.name), kind: a.kind }))))
    })
    this.setOpen(this.readOpen())
    this.scrollToEnd()
  }

  // ---------- apertura e chiusura ----------

  open() { this.setOpen(true); this.inputTarget.focus() }
  close() { this.setOpen(false); this.openerTarget.focus() }

  setOpen(open) {
    this.panelTarget.hidden = !open
    this.openerTarget.hidden = open
    this.element.closest(".con-assistente")?.classList.toggle("assistente-chiuso", !open)
    try { localStorage.setItem(OPEN_KEY, open ? "1" : "0") } catch {}
  }

  readOpen() {
    try { return localStorage.getItem(OPEN_KEY) !== "0" } catch { return true }
  }

  // ---------- invio ----------

  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.send()
    }
  }

  suggest(event) {
    this.inputTarget.value = event.currentTarget.textContent.trim()
    this.send()
  }

  // ---------- allegati ----------

  chooseFiles() {
    this.fileInputTarget.click()
  }

  filesChosen() {
    this.addFiles(this.fileInputTarget.files)
    this.fileInputTarget.value = ""
  }

  dragOver(event) {
    if (this.busy || !event.dataTransfer?.types?.includes("Files")) return
    event.preventDefault()
    this.panelTarget.classList.add("trascina-qui")
  }

  dragLeave(event) {
    if (!this.panelTarget.contains(event.relatedTarget)) this.panelTarget.classList.remove("trascina-qui")
  }

  drop(event) {
    if (!event.dataTransfer?.files?.length) return
    event.preventDefault()
    this.panelTarget.classList.remove("trascina-qui")
    if (!this.busy) this.addFiles(event.dataTransfer.files)
  }

  addFiles(list) {
    const accepted = this.fileInputTarget.accept.split(",").filter((a) => a.startsWith("."))
    const rejected = []
    for (const file of list) {
      const extension = "." + file.name.split(".").pop().toLowerCase()
      if (!accepted.includes(extension)) rejected.push(file.name)
      else if (this.pendingFiles.length >= MAX_FILES) rejected.push(`${file.name} (massimo ${MAX_FILES} file)`)
      else if (file.size > MAX_FILE_SIZE) rejected.push(`${file.name} (oltre 100 MB)`)
      else this.pendingFiles.push(file)
    }
    this.renderPending()
    if (rejected.length) {
      this.statusTarget.textContent = `Non allegati: ${rejected.join(", ")}. Si possono allegare testi, PDF, immagini e video.`
      clearTimeout(this.statusTimer)
      this.statusTimer = setTimeout(() => { this.statusTarget.textContent = "" }, 6000)
    }
    this.inputTarget.focus()
  }

  renderPending() {
    this.pendingTarget.replaceChildren(...this.pendingFiles.map((file, index) => {
      const item = document.createElement("li")
      item.className = "allegato"
      item.append(this.fileIcon(file.name), Object.assign(document.createElement("span"), {
        className: "allegato-nome", textContent: `${file.name} · ${humanSize(file.size)}`
      }))
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "allegato-togli"
      remove.textContent = "×"
      remove.setAttribute("aria-label", `Togli ${file.name}`)
      remove.addEventListener("click", () => { this.pendingFiles.splice(index, 1); this.renderPending(); this.inputTarget.focus() })
      item.append(remove)
      return item
    }))
    this.pendingTarget.hidden = this.pendingFiles.length === 0
  }

  fileIcon(name) {
    const icon = document.createElement("span")
    icon.className = "allegato-icona"
    icon.setAttribute("aria-hidden", "true")
    icon.textContent = /\.(jpe?g|png|gif|webp|heic|heif)$/i.test(name) ? "🖼️" : /\.(mp4|mov|m4v|webm)$/i.test(name) ? "🎬" : "📄"
    return icon
  }

  // I file inviati con un messaggio, mostrati sotto il messaggio stesso.
  attachmentList(files) {
    const list = document.createElement("ul")
    list.className = "msg-allegati"
    files.forEach(({ name, url, local }) => {
      const item = document.createElement("li")
      const isImage = /\.(jpe?g|png|gif|webp)$/i.test(name)
      const isVideo = /\.(mp4|mov|m4v|webm)$/i.test(name)
      const link = document.createElement("a")
      link.href = url
      link.target = "_blank"
      link.rel = "noopener"
      // Immagini e video si aprono a tutto schermo; testi e PDF in una nuova scheda.
      if (isImage || isVideo) {
        Object.assign(link.dataset, { lightbox: local || url, lightboxGroup: "chat-allegati", lightboxCaption: name,
                                      lightboxType: isVideo ? "video" : "image" })
      }
      if (isImage) {
        const img = document.createElement("img")
        img.src = local || url
        img.alt = name
        img.addEventListener("error", () => img.replaceWith(this.fileIcon(name)))
        link.append(img)
      } else link.append(this.fileIcon(name))
      link.append(Object.assign(document.createElement("span"), { textContent: name }))
      item.append(link)
      list.append(item)
    })
    return list
  }

  fileUrl(name) {
    return this.fileUrlValue.replace("__NOME__", encodeURIComponent(name))
  }

  // ---------- invio ----------

  async send() {
    let text = this.inputTarget.value.trim()
    const files = [...this.pendingFiles]
    if ((!text && !files.length) || this.busy) return
    if (!text) text = "Ti allego questi file."

    this.introTarget.hidden = true
    const sent = this.addMessage("user", text)
    if (files.length) {
      sent.append(this.attachmentList(files.map((f) => ({ name: f.name, url: URL.createObjectURL(f), local: URL.createObjectURL(f) }))))
    }
    this.inputTarget.value = ""
    this.pendingFiles = []
    this.renderPending()
    const reply = this.addMessage("assistant", "")
    const body = reply.querySelector(".msg-corpo")
    const activity = document.createElement("ul")
    activity.className = "msg-attivita"
    reply.prepend(activity)
    this.working = document.createElement("div")
    this.working.className = "msg-lavoro"
    this.working.innerHTML = `<span class="puntini" aria-hidden="true"><i></i><i></i><i></i></span><span class="msg-lavoro-testo"></span>`
    reply.append(this.working)

    this.writerTyping = false
    this.activityTyping = 0
    this.setBusy(true, "Claude sta pensando…")
    this.controller = new AbortController()
    let raw = ""
    const writer = new Typewriter((shown, typing) => {
      this.renderInto(body, shown, true, !typing)
      if (typing) this.appendCaret(body)
      this.writerTyping = typing
      this.updateIndicator()
      this.scrollToEnd()
    })

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content, Accept: "application/x-ndjson" },
        body: this.payload(text, files),
        signal: this.controller.signal
      })
      if (!response.ok || !response.body) {
        const detail = await response.json().then((j) => j.error).catch(() => null)
        throw new Error(detail || `il server ha risposto con l'errore ${response.status}.`)
      }

      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ""
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        let newline
        while ((newline = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, newline).trim()
          buffer = buffer.slice(newline + 1)
          if (!line) continue
          const event = JSON.parse(line)
          if (event.type === "delta") {
            raw += event.text
            writer.push(event.text)
            this.setBusy(true, "Claude sta lavorando…")
          } else if (event.type === "activity") {
            const item = document.createElement("li")
            activity.append(item)
            this.activityTyping += 1
            typeInto(item, event.text, () => { this.activityTyping -= 1; this.updateIndicator() })
            this.setBusy(true, event.text)
            this.scrollToEnd()
          } else if (event.type === "done" && event.error) {
            this.addError(reply, event.error)
          }
        }
      }
      await writer.finished()
    } catch (error) {
      writer.flush()
      if (error.name === "AbortError") raw += "\n\n_(risposta interrotta)_"
      else this.addError(reply, `Non sono riuscito a parlare con Claude: ${error.message}`)
    } finally {
      writer.stop()
      this.renderInto(body, raw, true)
      if (!raw.trim() && !reply.querySelector(".msg-errore")) body.textContent = "(nessuna risposta)"
      this.working.remove()
      this.setBusy(false)
      this.scrollToEnd()
      this.inputTarget.focus()
    }
  }

  stop() {
    this.controller?.abort()
  }

  appendCaret(container) {
    const caret = document.createElement("span")
    caret.className = "cursore"
    caret.setAttribute("aria-hidden", "true")
    const last = container.lastElementChild
    ;(last && last.tagName !== "DIV" ? last : container).append(caret)
  }

  payload(text, files = []) {
    const data = new FormData()
    data.append("message", text)
    files.forEach((file) => data.append("files[]", file, file.name))
    data.append("token", this.tokenValue)
    if (this.postIdValue) data.append("post_id", this.postIdValue)
    data.append("form_state", JSON.stringify(this.formState()))
    return data
  }

  // Quello che c'è nel form adesso, anche se non è ancora salvato.
  formState() {
    const form = this.postForm()
    if (!form) return {}
    const value = (selector) => form.querySelector(selector)?.value ?? ""
    const kept = [...form.querySelectorAll(".galleria-ordinabile figure:not(.da-rimuovere) figcaption > span:first-child")].map((s) => s.textContent.trim())
    const input = form.querySelector("input[type=file][name='post[media][]']")
    return {
      title: value(FIELDS.titolo.selector),
      body: value(FIELDS.testo.selector),
      notes: value(FIELDS.note.selector),
      publish_at: value(FIELDS.data.selector),
      status: form.querySelector(".stato-fisso .pill")?.textContent.trim(),
      pages: [...form.querySelectorAll("input[name='post[social_page_ids][]']:checked")].map((c) => c.closest("label")?.title || c.value),
      media: kept,
      new_files: input ? [...input.files].map((f) => f.name) : []
    }
  }

  postForm() {
    return this.element.closest(".con-assistente")?.querySelector("form.modulo")
  }

  // Mentre Claude lavora: pallino che pulsa nella testata e campo di scrittura bloccato,
  // resta solo «Interrompi».
  setBusy(busy, text = "") {
    this.busy = busy
    this.element.classList.toggle("al-lavoro", busy)
    this.sendTarget.hidden = busy
    this.stopTarget.hidden = !busy
    this.attachTarget.disabled = busy
    this.inputTarget.disabled = busy
    this.inputTarget.placeholder = busy ? "Attendi che Claude finisca…" : this.idlePlaceholder
    this.statusTarget.textContent = ""
    const label = this.working?.querySelector(".msg-lavoro-testo")
    if (label) label.textContent = text
    this.updateIndicator()
  }

  // I puntini compaiono solo nelle pause: tocca a Claude, ma in chat non sta comparendo nessun carattere
  // (sta ragionando, leggendo file o eseguendo comandi). Mentre il testo compare, spariscono.
  updateIndicator() {
    if (!this.working) return
    this.working.hidden = !(this.busy && !this.writerTyping && this.activityTyping === 0)
  }

  // ---------- messaggi ----------

  addMessage(role, text) {
    const message = document.createElement("div")
    message.className = `msg msg-${role}`
    const body = document.createElement("div")
    body.className = "msg-corpo"
    message.append(body)
    this.renderInto(body, text, role === "assistant")
    this.messagesTarget.append(message)
    this.scrollToEnd()
    return message
  }

  addError(message, text) {
    const error = document.createElement("p")
    error.className = "msg-errore"
    error.textContent = text
    message.append(error)
  }

  scrollToEnd() {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }

  // Un markdown minimo: paragrafi, **grassetto**, `codice`, _corsivo_, blocchi di codice e proposte.
  // A risposta completa (final), con almeno due proposte, aggiunge il pulsante per applicarle tutte.
  renderInto(container, raw, withProposals, final = true) {
    container.replaceChildren()
    const parts = raw.split(/```/)
    parts.forEach((part, index) => {
      if (index % 2 === 0) {
        part.split(/\n{2,}/).filter((p) => p.trim()).forEach((paragraph) => {
          const p = document.createElement("p")
          p.innerHTML = this.inline(paragraph.trim())
          container.append(p)
        })
        return
      }
      const newline = part.indexOf("\n")
      const info = (newline >= 0 ? part.slice(0, newline) : part).trim()
      const content = newline >= 0 ? part.slice(newline + 1).replace(/\n$/, "") : ""
      const closed = index < parts.length - 1
      const kind = info.match(/^proposta:(\w+)/)?.[1]
      if (withProposals && kind && FIELDS[kind] && closed) container.append(this.proposal(kind, content))
      else {
        const pre = document.createElement("pre")
        pre.textContent = content || info
        container.append(pre)
      }
    })

    const boxes = [...container.querySelectorAll(".proposta")]
    if (withProposals && final && boxes.length >= 2) container.append(this.applyAllBar(boxes))
  }

  // «Applica tutte le proposte»: le applica nell'ordine in cui compaiono (i file in coda, nell'ordine proposto),
  // saltando quelle già applicate e i file non più disponibili.
  applyAllBar(boxes) {
    const bar = document.createElement("div")
    bar.className = "proposte-tutte"
    const button = document.createElement("button")
    button.type = "button"
    button.className = "bottone bottone-principale"
    button.textContent = `Applica tutte le proposte (${boxes.length})`
    button.addEventListener("click", async () => {
      button.disabled = true
      button.textContent = "Applico le proposte…"
      let applied = 0, skipped = 0, failed = 0
      for (const box of boxes) {
        if (box.querySelector(".bottone-piccolo-pieno").disabled) { skipped += 1; continue }
        ;(await box.applyProposal({ scroll: false })) ? applied += 1 : failed += 1
      }
      const parts = [ `Applicate ${applied}` ]
      if (skipped) parts.push(`${skipped} già applicate o non disponibili`)
      if (failed) parts.push(`${failed} non riuscite`)
      button.textContent = failed ? parts.join(", ") : `${parts.join(", ")} ✓ · ricordati di salvare`
      button.disabled = !failed
      this.postForm()?.scrollIntoView({ behavior: "smooth", block: "start" })
    })
    bar.append(button)
    return bar
  }

  inline(text) {
    const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    return escaped
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|\s)_([^_]+)_(?=\s|$|[.,;:!?])/g, "$1<em>$2</em>")
      .replace(/\n/g, "<br>")
  }

  // ---------- proposte ----------

  proposal(kind, content) {
    const box = document.createElement("div")
    box.className = `proposta proposta-${kind}`
    const title = document.createElement("div")
    title.className = "proposta-etichetta"
    title.textContent = `Proposta · ${FIELDS[kind].label}`
    box.append(title)

    if (kind === "file") {
      const name = content.trim().split("/").pop()
      const url = this.fileUrlValue.replace("__NOME__", encodeURIComponent(name))
      const preview = /\.(mp4|mov|webm)$/i.test(name) ? document.createElement("video") : document.createElement("img")
      preview.src = url
      if (preview.tagName === "VIDEO") preview.controls = true
      else preview.alt = name
      const link = document.createElement("a")
      link.href = url
      link.target = "_blank"
      link.rel = "noopener"
      // Clic: anteprima a tutto schermo; le proposte di file della chat si scorrono con ← →.
      Object.assign(link.dataset, { lightbox: url, lightboxGroup: "chat-proposte", lightboxCaption: name,
                                    lightboxType: preview.tagName === "VIDEO" ? "video" : "image" })
      link.title = "Clic per vederlo a tutto schermo"
      link.append(preview)
      const caption = document.createElement("div")
      caption.className = "proposta-nome"
      caption.textContent = name
      box.append(link, caption)
      box.dataset.url = url
      box.dataset.name = name
    } else {
      const text = document.createElement("div")
      text.className = "proposta-testo"
      text.textContent = content
      box.append(text)
    }

    const button = document.createElement("button")
    button.type = "button"
    button.className = "bottone bottone-piccolo-pieno"
    button.textContent = kind === "file" ? "Aggiungi al post" : "Applica al form"
    box.applyProposal = (options) => this.apply(kind, content, box, button, options)
    button.addEventListener("click", () => box.applyProposal())
    box.append(button)

    // Un file che non c'è più (cartella di lavoro svuotata): niente link rotto, lo si dice.
    const media = box.querySelector("img, video")
    media?.addEventListener("error", () => {
      const missing = document.createElement("p")
      missing.className = "proposta-mancante"
      missing.textContent = "Questo file non è più disponibile: chiedi a Claude di ricrearlo."
      media.closest("a").replaceWith(missing)
      button.disabled = true
      button.textContent = "File non disponibile"
    })
    return box
  }

  // Applica una proposta al form; restituisce true se è andata a buon fine.
  async apply(kind, content, box, button, { scroll = true } = {}) {
    const form = this.postForm()
    if (!form) return false

    try {
      if (kind === "file") {
        const response = await fetch(box.dataset.url)
        if (!response.ok) throw new Error("il file non si trova più nella cartella di lavoro di Claude")
        const blob = await response.blob()
        const input = form.querySelector("input[type=file][name='post[media][]']")
        const transfer = new DataTransfer()
        ;[...input.files].forEach((f) => transfer.items.add(f))
        transfer.items.add(new File([blob], box.dataset.name, { type: blob.type }))
        input.files = transfer.files
        input.dispatchEvent(new Event("input", { bubbles: true }))
        input.dispatchEvent(new Event("change", { bubbles: true }))
        this.highlight(form.querySelector(".galleria-nuovi") || input, scroll)
      } else {
        const field = form.querySelector(FIELDS[kind].selector)
        field.value = kind === "data" ? content.trim().slice(0, 16) : content
        field.dispatchEvent(new Event("input", { bubbles: true }))
        this.highlight(field, scroll)
      }
      button.textContent = "Applicato ✓ · ricordati di salvare"
      button.disabled = true
      return true
    } catch (error) {
      button.textContent = `Non applicato: ${error.message}`
      return false
    }
  }

  highlight(element, scroll = true) {
    if (scroll) element.scrollIntoView({ behavior: "smooth", block: "center" })
    element.classList.remove("appena-applicato")
    void element.offsetWidth
    element.classList.add("appena-applicato")
  }
}
