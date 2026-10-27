import { Controller } from "@hotwired/stimulus"

// «Proponi post con Claude»: la finestra che avvia Claude in background, ne mostra l'avanzamento
// e le proposte una alla volta, e alla fine le crea come bozze (o annulla tutto).
// Chiudendo la finestra mentre Claude lavora, il lavoro continua: il bottone lo riapre.
export default class extends Controller {
  static targets = ["dialog", "intro", "work", "status", "spinner", "activity", "elapsed", "thought", "list", "empty",
                    "rejected", "summary", "introButtons", "runningButtons", "finalButtons", "approve", "card", "opener"]
  static values = { url: String }

  connect() {
    this.reset()
  }

  // Lasciando la pagina a lavoro in corso o con proposte non approvate: si ferma tutto e si butta via.
  disconnect() {
    this.abort?.abort()
    if (this.token && this.phase !== "intro") this.request("DELETE", this.sessionUrl(), { keepalive: true })
    clearInterval(this.timer)
  }

  open() {
    if (!this.dialogTarget.open) this.dialogTarget.showModal()
  }

  close(event) {
    event?.preventDefault()
    this.dialogTarget.close()
    if (this.phase === "intro") this.reset()
  }

  async start() {
    this.token = crypto.randomUUID()
    this.proposals = new Map()
    this.setPhase("running")
    this.startedAt = Date.now()
    this.timer = setInterval(() => this.tick(), 1000)
    this.tick()
    this.abort = new AbortController()

    let finished = false
    try {
      const body = new FormData()
      body.append("token", this.token)
      const response = await fetch(this.urlValue, {
        method: "POST", body, signal: this.abort.signal,
        headers: { "X-CSRF-Token": this.csrf(), Accept: "application/x-ndjson" }
      })
      if (!response.ok) throw new Error((await response.json().catch(() => ({}))).error || `errore ${response.status}`)

      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ""
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split("\n")
        buffer = lines.pop()
        for (const line of lines) {
          if (!line.trim()) continue
          const event = JSON.parse(line)
          if (event.type === "done") {
            finished = true
            this.finish(event.error ? `Claude si è fermato: ${event.error}` : event.summary)
          } else {
            this.handle(event)
          }
        }
      }
      if (!finished) this.finish("Claude si è fermato prima di finire.")
    } catch (error) {
      if (!finished) this.finish(error.name === "AbortError" ? "Interrotto: restano le proposte arrivate finora." : `Errore: ${error.message}`)
    }
  }

  stop() {
    this.abort?.abort()
  }

  handle(event) {
    switch (event.type) {
      case "activity":
        this.activityTarget.textContent = event.text
        break
      case "status":
        this.thoughtTarget.hidden = false
        this.thoughtTarget.textContent = this.plain(event.text)
        break
      case "proposal":
        this.addCard(event.proposal)
        break
      case "rejected": {
        const item = document.createElement("li")
        item.textContent = event.text
        this.rejectedTarget.append(item)
        break
      }
    }
  }

  finish(summary) {
    this.abort = null
    clearInterval(this.timer)
    this.tick()
    this.setPhase("final")
    this.summaryTarget.textContent = this.plain(summary || "")
    this.activityTarget.textContent = this.proposals.size ? "Claude ha finito." : "Claude ha finito, senza proposte."
    this.updateCount()
  }

  addCard(proposal) {
    const card = this.cardTarget.content.firstElementChild.cloneNode(true)
    card.dataset.id = proposal.id
    const photo = card.querySelector(".proposta-post-foto")
    const first = proposal.files[0]
    if (first) {
      const media = document.createElement(first.video ? "video" : "img")
      media.src = first.url
      if (first.video) { media.muted = true; media.preload = "metadata" } else { media.alt = ""; media.loading = "lazy" }
      photo.append(media)
      proposal.files.forEach((file, index) => {
        const target = index === 0 ? media : document.createElement("span")
        Object.assign(target.dataset, { lightbox: file.url, lightboxGroup: `proposta-${proposal.id}`,
                                        lightboxCaption: file.name, lightboxType: file.video ? "video" : "image" })
        if (index > 0) { target.hidden = true; photo.append(target) }
      })
      if (proposal.files.length > 1) {
        const count = document.createElement("span")
        count.className = "proposta-post-conta"
        count.textContent = proposal.files.length
        photo.append(count)
      }
    } else {
      photo.classList.add("senza-foto")
      photo.textContent = "senza immagine"
    }
    card.querySelector(".proposta-post-data").textContent = [proposal.date, proposal.when].filter(Boolean).join(" · ")
    card.querySelector(".proposta-post-titolo").textContent = proposal.title
    const firstLine = (proposal.body || "").split("\n").find((line) => line.trim())
    card.querySelector(".proposta-post-estratto").textContent = firstLine || "Testo da scrivere"
    card.querySelector(".proposta-post-motivo").textContent = proposal.reason
    card.querySelector(".proposta-post-corpo").textContent = proposal.body || "(nessun testo)"
    card.querySelector(".proposta-post-note").textContent = proposal.notes || ""
    if (proposal.notes) card.classList.add("con-note")
    card.querySelector(".proposta-post-togli").addEventListener("click", () => this.remove(card))

    this.proposals.set(String(proposal.id), proposal)
    this.listTarget.append(card)
    this.emptyTarget.hidden = true
    this.updateCount()
    card.scrollIntoView({ block: "nearest", behavior: "smooth" })
  }

  remove(card) {
    this.proposals.delete(card.dataset.id)
    card.remove()
    this.emptyTarget.hidden = this.proposals.size > 0
    if (!this.proposals.size) this.emptyTarget.textContent = this.phase === "final" ? "Nessuna proposta rimasta." : "Nessuna proposta tenuta, per ora."
    this.updateCount()
  }

  async approve() {
    this.approveTarget.disabled = true
    this.approveTarget.textContent = "Creo le bozze…"
    const body = new FormData()
    this.proposals.forEach((_, id) => body.append("ids[]", id))
    try {
      const response = await this.request("POST", `${this.sessionUrl()}/approva`, { body })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || `errore ${response.status}`)
      this.phase = "intro" // la cartella è già stata cancellata dal server
      this.dialogTarget.close()
      window.Turbo ? window.Turbo.visit(data.redirect, { action: "replace" }) : (window.location = data.redirect)
    } catch (error) {
      this.summaryTarget.textContent = error.message
      this.updateCount()
    }
  }

  async discard() {
    await this.request("DELETE", this.sessionUrl()).catch(() => {})
    this.dialogTarget.close()
    this.reset()
  }

  // ---- stato della finestra ----

  reset() {
    this.token = null
    this.proposals = new Map()
    this.listTarget.replaceChildren()
    this.rejectedTarget.replaceChildren()
    this.emptyTarget.hidden = false
    this.emptyTarget.textContent = "Ancora nessuna proposta: Claude sta studiando la situazione."
    this.thoughtTarget.hidden = true
    this.summaryTarget.textContent = ""
    this.activityTarget.textContent = "Avvio di Claude…"
    this.elapsedTarget.textContent = ""
    this.setPhase("intro")
  }

  setPhase(phase) {
    this.phase = phase
    this.introTarget.hidden = phase !== "intro"
    this.workTarget.hidden = phase === "intro"
    this.introButtonsTarget.hidden = phase !== "intro"
    this.runningButtonsTarget.hidden = phase !== "running"
    this.finalButtonsTarget.hidden = phase !== "final"
    this.spinnerTarget.hidden = phase !== "running"
    this.dialogTarget.classList.toggle("al-lavoro", phase === "running")
    this.openerTargets.forEach((button) => {
      button.classList.toggle("al-lavoro", phase === "running")
      button.querySelector(".etichetta").textContent =
        phase === "running" ? "Claude al lavoro…" : phase === "final" ? "Proposte di Claude pronte" : "Proponi post con Claude"
    })
  }

  updateCount() {
    const count = this.proposals.size
    this.approveTarget.disabled = count === 0
    this.approveTarget.textContent = count === 1 ? "Crea 1 bozza" : count ? `Crea ${count} bozze` : "Crea le bozze"
  }

  tick() {
    const seconds = Math.round((Date.now() - this.startedAt) / 1000)
    this.elapsedTarget.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
  }

  // ---- utilità ----

  sessionUrl() {
    return `${this.urlValue}/${this.token}`
  }

  request(method, url, options = {}) {
    return fetch(url, { method, headers: { "X-CSRF-Token": this.csrf(), Accept: "application/json" }, ...options })
  }

  csrf() {
    return document.querySelector("meta[name='csrf-token']")?.content
  }

  // Le frasi di Claude possono contenere un po' di Markdown: qui basta il testo.
  plain(text) {
    return String(text).replace(/\*\*|__|`/g, "").replace(/^#+\s*/, "")
  }
}
