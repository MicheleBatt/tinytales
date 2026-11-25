import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Appena la pagina è sullo schermo chiede all'app i numeri aggiornati dai social (visualizzazioni e persone raggiunte):
// la risposta è un Turbo Stream che sostituisce sul posto i numeri e i grafici mostrati con l'ultima lettura salvata.
// Se qualcosa va storto restano quelli: nessun errore a schermo.
// Va su un elemento che la risposta non sostituisce, altrimenti ripartirebbe a ogni aggiornamento.
export default class extends Controller {
  static values = { url: String }

  async connect() {
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "text/vnd.turbo-stream.html" } })
      if (response.ok) Turbo.renderStreamMessage(await response.text())
    } catch (error) {
      console.warn("Statistiche non aggiornate:", error)
    }
  }
}
