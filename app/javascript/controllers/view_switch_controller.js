import { Controller } from "@hotwired/stimulus"

// Le icone delle viste sono link (?vista=lista|griglia|calendario).
// Se la pagina mostra già lista o griglia, il passaggio fra queste due avviene qui, senza ricaricare:
// si scambia la classe dell'elenco e si salva la scelta nel cookie letto dal server.
// Il calendario, e il ritorno dal calendario, passano invece dal server.
export default class extends Controller {
  static targets = ["list", "button"]

  show(event) {
    const view = event.currentTarget.dataset.view
    if (!this.hasListTarget || view === "calendario") return

    event.preventDefault()
    this.listTarget.classList.toggle("vista-griglia", view === "griglia")
    this.buttonTargets.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.view === view)))
    document.cookie = `vista_post=${view}; path=/; max-age=${60 * 60 * 24 * 365}; samesite=lax`
  }
}
