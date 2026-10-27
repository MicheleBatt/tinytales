// Mentre un'azione parla con i social (pubblica, programma, spubblica, elimina, salva un post già online),
// copre la pagina con un velo, uno spinner e un messaggio, finché non arriva la risposta.
// Basta mettere sul form data-busy-message="…": il velo compare quando la richiesta parte davvero
// (cioè dopo la finestra di conferma) e sparisce con la pagina nuova.
//
// Il velo è un <dialog> modale, così sta sopra anche alle altre finestre. Se l'azione parte dal popup
// del calendario, il popup si chiude; e se la richiesta non arriva (rete, errore del server) il velo
// mostra l'errore invece di sparire. Gli errori di Facebook arrivano invece con la pagina nuova,
// in una finestra a sé (shared/_errore_popup).
const SLOW_AFTER = 20_000
const WAIT_TEXT = "Di solito bastano pochi secondi: non chiudere la pagina."

let overlay
let slowTimer
let fromPopup = false

function build() {
  overlay = document.createElement("dialog")
  overlay.className = "attesa"
  overlay.setAttribute("aria-live", "assertive")
  overlay.innerHTML = `
    <div class="attesa-riquadro" role="status">
      <span class="attesa-spinner" aria-hidden="true"></span>
      <p class="attesa-messaggio"></p>
      <p class="attesa-sotto"></p>
      <button type="button" class="bottone bottone-principale attesa-chiudi" hidden>Chiudi</button>
    </div>`
  // Mentre si aspetta non si chiude con Esc; dopo un errore sì.
  overlay.addEventListener("cancel", (event) => { if (!overlay.classList.contains("attesa-errore")) event.preventDefault() })
  overlay.querySelector(".attesa-chiudi").addEventListener("click", hide)
  return overlay
}

function show(message) {
  const box = overlay?.isConnected ? overlay : build()
  box.classList.remove("attesa-lenta", "attesa-errore")
  box.querySelector(".attesa-messaggio").textContent = message
  box.querySelector(".attesa-sotto").textContent = WAIT_TEXT
  box.querySelector(".attesa-chiudi").hidden = true
  document.body.append(box)
  if (!box.open) box.showModal()
  document.body.setAttribute("aria-busy", "true")
  clearTimeout(slowTimer)
  slowTimer = setTimeout(() => {
    box.classList.add("attesa-lenta")
    box.querySelector(".attesa-sotto").textContent = "Ci sta mettendo più del solito: aspetta ancora un momento, la risposta di Facebook è in arrivo."
  }, SLOW_AFTER)
}

function showError(text) {
  clearTimeout(slowTimer)
  document.body.removeAttribute("aria-busy")
  const box = overlay
  box.classList.remove("attesa-lenta")
  box.classList.add("attesa-errore")
  box.querySelector(".attesa-messaggio").textContent = "L'azione non è riuscita"
  box.querySelector(".attesa-sotto").textContent = text
  const close = box.querySelector(".attesa-chiudi")
  close.hidden = false
  close.focus()
}

function hide() {
  clearTimeout(slowTimer)
  if (overlay?.open) overlay.close()
  overlay?.remove()
  document.body.removeAttribute("aria-busy")
}

document.addEventListener("turbo:submit-start", (event) => {
  const form = event.target.closest?.("form[data-busy-message]")
  if (!form) return

  // Dal popup del calendario: il popup sparisce, resta solo il velo.
  const popup = form.closest("dialog.popup-anteprima")
  fromPopup = Boolean(popup)
  if (popup?.open) popup.close()
  show(form.dataset.busyMessage)
})

// Se la richiesta è andata bene arriva una pagina nuova (e il velo se ne va con lei).
// Se no: un form con errori (422) torna con la pagina e i suoi messaggi, e il velo sparisce;
// per un'azione dal popup senza risposta utile (rete, errore del server) il velo mostra l'errore.
document.addEventListener("turbo:submit-end", (event) => {
  if (event.detail.success || !overlay?.isConnected) return

  const status = event.detail.fetchResponse?.statusCode
  if (fromPopup && status !== 422) {
    showError(status ? `Il server ha risposto con un errore (${status}). Riprova tra poco; se succede ancora, apri il post e riprova da lì.`
                     : "La richiesta non è arrivata: controlla la connessione e riprova.")
  } else {
    hide()
  }
})
document.addEventListener("turbo:load", hide)
// Il velo non deve finire nella copia della pagina che Turbo conserva per il tasto «indietro».
document.addEventListener("turbo:before-cache", hide)
