import { Controller } from "@hotwired/stimulus"

// Vista a calendario: il clic su un post apre un popup con la sua anteprima (bottoni compresi)
// invece della pagina del post. Il link resta vero: Ctrl/⌘-clic o clic centrale lo aprono in una nuova scheda.
// Dopo un'azione del popup (programma, elimina…) l'app torna qui, sullo stesso mese.
//
// Turbo conserva una copia della pagina per il tasto «indietro». Se la copia viene fatta con il popup aperto, al ritorno
// il popup risulta aperto ma non modale, e showModal() lo rifiuta: i clic sui post non aprirebbero più niente.
// Per questo il popup si chiude e si svuota prima che Turbo faccia la copia, e prima di aprirlo si chiude se risulta aperto.
export default class extends Controller {
  static targets = ["dialog", "content"]

  connect() {
    this.beforeCache = () => this.reset()
    document.addEventListener("turbo:before-cache", this.beforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.beforeCache)
  }

  async open(event) {
    if (event.button > 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return

    const link = event.currentTarget
    event.preventDefault()
    if (this.dialogTarget.open) this.dialogTarget.close()
    this.contentTarget.replaceChildren()
    this.contentTarget.setAttribute("aria-busy", "true")
    this.dialogTarget.showModal()

    const back = window.location.pathname + window.location.search
    const url = `${link.dataset.previewUrl}?return_to=${encodeURIComponent(back)}`
    try {
      const response = await fetch(url, { headers: { Accept: "text/html" } })
      if (!response.ok) throw new Error(`errore ${response.status}`)
      this.contentTarget.innerHTML = await response.text()
    } catch (error) {
      this.contentTarget.innerHTML = ""
      const message = document.createElement("p")
      message.className = "vuoto"
      message.textContent = `Anteprima non disponibile (${error.message}). `
      const fallback = Object.assign(document.createElement("a"), { href: link.href, textContent: "Apri la pagina del post" })
      message.append(fallback)
      this.contentTarget.append(message)
    } finally {
      this.contentTarget.removeAttribute("aria-busy")
    }
  }

  close() {
    this.dialogTarget.close()
  }

  // Popup chiuso e vuoto, com'era all'apertura della pagina.
  reset() {
    if (this.dialogTarget.open) this.dialogTarget.close()
    this.contentTarget.replaceChildren()
    this.contentTarget.removeAttribute("aria-busy")
  }

  // Clic sullo sfondo, fuori dal riquadro: chiude.
  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
