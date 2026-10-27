import { Controller } from "@hotwired/stimulus"

// Un <dialog> che si apre da solo appena compare nella pagina (per esempio la finestra d'errore).
export default class extends Controller {
  connect() {
    if (!this.element.open) this.element.showModal()
    this.element.addEventListener("click", (event) => { if (event.target === this.element) this.close() })
  }

  close() {
    this.element.close()
    this.element.remove() // non deve ricomparire tornando indietro con il browser
  }
}
