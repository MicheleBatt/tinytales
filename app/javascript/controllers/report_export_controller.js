import { Controller } from "@hotwired/stimulus"
import { showBusy, showBusyError, hideBusy } from "busy_overlay"

// «Esporta PDF» nell'elenco dei post: chiede il report con i filtri attuali (già nell'indirizzo del link),
// copre la pagina con il velo d'attesa mentre il server lo prepara e, quando è pronto, lo scarica da solo.
export default class extends Controller {
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
      const response = await fetch(this.element.href, { headers: { Accept: "application/pdf" } })
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

  filename(response) {
    const header = response.headers.get("Content-Disposition") || ""
    const match = header.match(/filename\*=UTF-8''([^;]+)/i) || header.match(/filename="?([^";]+)"?/i)
    return match ? decodeURIComponent(match[1]) : "report-post.pdf"
  }
}
