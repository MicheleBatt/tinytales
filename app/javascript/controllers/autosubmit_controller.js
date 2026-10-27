import { Controller } from "@hotwired/stimulus"

// Invia il form appena cambia un campo (per esempio il mese scelto nel calendario).
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
