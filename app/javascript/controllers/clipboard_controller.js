import { Controller } from "@hotwired/stimulus"

// Copia il testo del post negli appunti, pronto da incollare in Meta Business Suite.
export default class extends Controller {
  static targets = ["source", "button"]

  async copy() {
    const text = this.sourceTarget.innerText
    try {
      await navigator.clipboard.writeText(text)
      this.flash("Copiato!")
    } catch {
      const range = document.createRange()
      range.selectNodeContents(this.sourceTarget)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      this.flash("Testo selezionato: premi Ctrl+C")
    }
  }

  flash(message) {
    this.buttonTarget.textContent = message
    clearTimeout(this.timer)
    this.timer = setTimeout(() => { this.buttonTarget.textContent = "Copia testo" }, 2500)
  }
}
