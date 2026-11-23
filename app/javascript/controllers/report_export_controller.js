import { Controller } from "@hotwired/stimulus"
import { showBusy, showBusyError, hideBusy } from "busy_overlay"

// «Esporta PDF» nell'elenco dei post: come «Filtra» invia il form dei filtri così come è compilato ora, anche
// se non è stato applicato, ma chiede il risultato in PDF. Copre la pagina con il velo d'attesa mentre il
// server lo prepara e, quando è pronto, lo scarica da solo.
export default class extends Controller {
  static values = { url: String }

  async download(event) {
    event.preventDefault()
    if (this.busy) return
    this.busy = true
    showBusy("Esportazione del report dei post in PDF…", {
      wait: "Sto preparando frontespizio, premessa, indice e le schede dei post scelti con i filtri. " +
            "Di solito bastano pochi secondi: il file si scaricherà da solo.",
      slow: "Ci sta mettendo più del solito: con tanti post e tante foto serve qualche secondo in più."
    })
    try {
      const response = await fetch(this.reportUrl(), { headers: { Accept: "application/pdf" } })
      if (!response.ok) {
        const detail = await response.json().then((json) => json.error).catch(() => null)
        throw new Error(detail || `il server ha risposto con l'errore ${response.status}.`)
      }
      const url = URL.createObjectURL(await response.blob())
      const link = Object.assign(document.createElement("a"), { href: url, download: this.filename(response) })
      document.body.append(link)
      link.click()
      link.remove()
      setTimeout(() => URL.revokeObjectURL(url), 30_000)
      hideBusy()
    } catch (error) {
      showBusyError(`Il PDF non è stato creato: ${error.message}`, "Esportazione non riuscita")
    } finally {
      this.busy = false
    }
  }

  // L'indirizzo del report con i valori attuali del form (solo i filtri compilati).
  reportUrl() {
    const filters = [ ...new FormData(this.element.form) ].filter(([ name, value ]) => name.startsWith("q[") && value !== "")
    const query = new URLSearchParams(filters).toString()
    return query ? `${this.urlValue}?${query}` : this.urlValue
  }

  filename(response) {
    const header = response.headers.get("Content-Disposition") || ""
    const match = header.match(/filename\*=UTF-8''([^;]+)/i) || header.match(/filename="?([^";]+)"?/i)
    return match ? decodeURIComponent(match[1]) : "report-post.pdf"
  }
}
