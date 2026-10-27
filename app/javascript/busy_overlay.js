// Mentre un'azione parla con i social (pubblica, programma, spubblica, elimina, salva un post già online),
// copre la pagina con un velo, uno spinner e un messaggio, finché non arriva la risposta.
// Basta mettere sul form data-busy-message="…": il velo compare quando la richiesta parte davvero
// (cioè dopo la finestra di conferma) e sparisce con la pagina nuova, o subito se la richiesta fallisce.
const SLOW_AFTER = 20_000

let overlay
let slowTimer

function build() {
  overlay = document.createElement("div")
  overlay.className = "attesa"
  overlay.setAttribute("role", "status")
  overlay.setAttribute("aria-live", "assertive")
  overlay.innerHTML = `
    <div class="attesa-riquadro">
      <span class="attesa-spinner" aria-hidden="true"></span>
      <p class="attesa-messaggio"></p>
      <p class="attesa-sotto">Di solito bastano pochi secondi: non chiudere la pagina.</p>
    </div>`
  return overlay
}

function show(message) {
  const box = overlay?.isConnected ? overlay : build()
  box.querySelector(".attesa-messaggio").textContent = message
  box.querySelector(".attesa-sotto").textContent = "Di solito bastano pochi secondi: non chiudere la pagina."
  box.classList.remove("attesa-lenta")
  document.body.append(box)
  document.body.setAttribute("aria-busy", "true")
  clearTimeout(slowTimer)
  slowTimer = setTimeout(() => {
    box.classList.add("attesa-lenta")
    box.querySelector(".attesa-sotto").textContent = "Ci sta mettendo più del solito: aspetta ancora un momento, la risposta di Facebook è in arrivo."
  }, SLOW_AFTER)
}

function hide() {
  clearTimeout(slowTimer)
  overlay?.remove()
  document.body.removeAttribute("aria-busy")
}

document.addEventListener("turbo:submit-start", (event) => {
  const message = event.target.closest?.("form[data-busy-message]")?.dataset.busyMessage
  if (message) show(message)
})

// Se la richiesta è andata bene arriva una pagina nuova (e il velo se ne va con lei);
// se non è andata bene (errore di rete, form con errori) lo si toglie subito.
document.addEventListener("turbo:submit-end", (event) => {
  if (!event.detail.success) hide()
})
document.addEventListener("turbo:load", hide)
// Il velo non deve finire nella copia della pagina che Turbo conserva per il tasto «indietro».
document.addEventListener("turbo:before-cache", hide)
