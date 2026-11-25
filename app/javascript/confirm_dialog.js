import { Turbo } from "@hotwired/turbo-rails"

// Al posto della finestra di conferma del browser (data-turbo-confirm), una finestra nello stile dell'app.
// Sul form (o sul link) si possono aggiungere, facoltativi:
//   data-confirm-title   il titolo della finestra (predefinito: «Confermi?»)
//   data-confirm-button  il testo del bottone che procede (predefinito: «Procedi»)
//   data-confirm-tone    «pericolo» per un bottone rosso (eliminare, togliere dai social), altrimenti blu
//   data-confirm-datetime-name   se c'è, la finestra mostra un campo data e ora (per esempio publish_at per Programma),
//   data-confirm-datetime-value  già compilato con questo valore (AAAA-MM-GGTHH:MM),
//   data-confirm-datetime-label / -help   etichetta e aiuto del campo; si accettano date da 10 minuti a 30 giorni da adesso.
// Annulla, ×, Esc o un clic fuori dalla finestra: non succede niente.
//
// Dentro un elemento con data-conferma-in-linea (i bottoni nel popup del calendario, che è già una finestra) la conferma
// non apre un'altra finestra sopra: si apre a fisarmonica una regione sotto i bottoni, con gli stessi testi e campi.
// Un secondo clic sullo stesso bottone la richiude; il clic su un altro bottone la sostituisce.
let dialog

function build() {
  dialog = document.createElement("dialog")
  dialog.className = "conferma"
  dialog.setAttribute("aria-labelledby", "conferma-titolo")
  dialog.setAttribute("aria-describedby", "conferma-messaggio")
  dialog.innerHTML = `
    <header class="conferma-testa">
      <h2 id="conferma-titolo"></h2>
      <button type="button" class="proposte-chiudi" data-esito="no" aria-label="Annulla">×</button>
    </header>
    <p class="conferma-messaggio" id="conferma-messaggio"></p>
    <div class="conferma-campo" hidden>
      <label for="conferma-data"></label>
      <input type="datetime-local" id="conferma-data" step="60" required>
      <span class="aiuto conferma-aiuto"></span>
      <span class="errore-campo conferma-errore" hidden></span>
    </div>
    <footer class="conferma-piede">
      <button type="button" class="bottone" data-esito="no">Annulla</button>
      <button type="button" class="bottone conferma-procedi" data-esito="si"></button>
    </footer>`
  document.body.append(dialog)
  return dialog
}

function confirmWithDialog(message, element) {
  const source = element?.closest?.("[data-confirm-title], [data-confirm-button], [data-confirm-tone]") || element
  const box = dialog?.isConnected ? dialog : build()
  const proceed = box.querySelector(".conferma-procedi")
  const danger = source?.dataset?.confirmTone === "pericolo"

  box.querySelector("#conferma-titolo").textContent = source?.dataset?.confirmTitle || "Confermi?"
  box.querySelector("#conferma-messaggio").textContent = message
  proceed.textContent = source?.dataset?.confirmButton || "Procedi"
  proceed.classList.toggle("bottone-pericolo-pieno", danger)
  proceed.classList.toggle("bottone-principale", !danger)
  box.classList.toggle("conferma-pericolo", danger)
  const field = setUpDateField(box, source)

  return new Promise((resolve) => {
    const finish = (answer) => {
      box.removeEventListener("click", onClick)
      box.removeEventListener("close", onClose)
      if (box.open) box.close()
      resolve(answer)
    }
    const onClick = (event) => {
      const choice = event.target.closest("[data-esito]")?.dataset.esito
      if (choice === "si" && field) {
        const error = field.error()
        if (error) return field.show(error)
        finish(false) // Turbo ha già preparato i dati del form: si rinvia con la data scelta
        resubmitWithDate(source.closest("form") || source, field.name, field.input.value)
      } else if (choice) finish(choice === "si")
      else if (event.target === box) finish(false) // clic sullo sfondo
    }
    const onClose = () => finish(false) // Esc
    box.addEventListener("click", onClick)
    box.addEventListener("close", onClose)
    box.showModal()
    // Per le azioni pericolose il cursore parte da «Annulla», così un Invio distratto non fa danni.
    ;(danger ? box.querySelector(".conferma-piede [data-esito=no]") : field ? field.input : proceed).focus()
  })
}

// ---------- conferma a fisarmonica, sotto i bottoni (popup del calendario) ----------

let pending = null // la conferma in linea aperta: { form, region, finish }

function confirmInline(message, element, container) {
  const form = element?.closest?.("form") || element
  const source = element?.closest?.("[data-confirm-title], [data-confirm-button], [data-confirm-tone]") || element

  // Secondo clic sullo stesso bottone: la regione si richiude.
  if (pending && pending.form === form) {
    pending.finish(false)
    return Promise.resolve(false)
  }
  pending?.finish(false, { keepOpen: true })

  const region = inlineRegion(container)
  const danger = source?.dataset?.confirmTone === "pericolo"
  region.querySelector(".conferma-in-linea-titolo").textContent = source?.dataset?.confirmTitle || "Confermi?"
  region.querySelector(".conferma-messaggio").textContent = message
  const proceed = region.querySelector(".conferma-procedi")
  proceed.textContent = source?.dataset?.confirmButton || "Procedi"
  proceed.classList.toggle("bottone-pericolo-pieno", danger)
  proceed.classList.toggle("bottone-principale", !danger)
  region.classList.toggle("conferma-pericolo", danger)
  const field = setUpDateField(region, source)

  const toggle = form.querySelector("button[type=submit], input[type=submit]")
  container.querySelectorAll("[aria-expanded]").forEach((button) => button.setAttribute("aria-expanded", "false"))
  toggle?.setAttribute("aria-expanded", "true")
  toggle?.setAttribute("aria-controls", region.id)
  region.hidden = false
  region.scrollIntoView({ block: "nearest" })

  return new Promise((resolve) => {
    const finish = (answer, { keepOpen = false } = {}) => {
      region.removeEventListener("click", onClick)
      region.removeEventListener("keydown", onKey)
      toggle?.setAttribute("aria-expanded", "false")
      if (!keepOpen) region.hidden = true
      if (pending?.form === form) pending = null
      resolve(answer)
    }
    const onClick = (event) => {
      const choice = event.target.closest("[data-esito]")?.dataset.esito
      if (choice === "si" && field) {
        const error = field.error()
        if (error) return field.show(error)
        finish(false) // Turbo ha già preparato i dati del form: si rinvia con la data scelta
        resubmitWithDate(form, field.name, field.input.value)
      } else if (choice) {
        finish(choice === "si")
        if (choice === "no") toggle?.focus()
      }
    }
    // Esc nella regione la richiude, senza chiudere il popup.
    const onKey = (event) => {
      if (event.key !== "Escape") return
      event.preventDefault()
      event.stopPropagation()
      finish(false)
      toggle?.focus()
    }
    region.addEventListener("click", onClick)
    region.addEventListener("keydown", onKey)
    pending = { form, region, finish }
    ;(danger ? region.querySelector(".conferma-piede [data-esito=no]") : field ? field.input : proceed).focus()
  })
}

// La regione sotto i bottoni, creata la prima volta (una per contenitore).
function inlineRegion(container) {
  let region = container.querySelector(".conferma-in-linea")
  if (region) return region

  const id = `conferma-in-linea-${Math.random().toString(36).slice(2, 8)}`
  region = document.createElement("section")
  region.className = "conferma-in-linea"
  region.id = id
  region.hidden = true
  region.setAttribute("role", "region")
  region.setAttribute("aria-labelledby", `${id}-titolo`)
  region.innerHTML = `
    <h3 class="conferma-in-linea-titolo" id="${id}-titolo"></h3>
    <p class="conferma-messaggio"></p>
    <div class="conferma-campo" hidden>
      <label for="${id}-data"></label>
      <input type="datetime-local" id="${id}-data" step="60" required>
      <span class="aiuto conferma-aiuto"></span>
      <span class="errore-campo conferma-errore" hidden></span>
    </div>
    <footer class="conferma-piede">
      <button type="button" class="bottone" data-esito="no">Annulla</button>
      <button type="button" class="bottone conferma-procedi" data-esito="si"></button>
    </footer>`
  container.append(region)
  return region
}

// Il campo data e ora, se il form lo chiede. Restituisce null se non serve.
function setUpDateField(box, source) {
  const wrapper = box.querySelector(".conferma-campo")
  const name = source?.dataset?.confirmDatetimeName
  wrapper.hidden = !name
  if (!name) return null

  const input = wrapper.querySelector("input")
  const message = wrapper.querySelector(".conferma-errore")
  const now = Date.now()
  const min = new Date(now + 10 * 60 * 1000)
  const max = new Date(now + 30 * 24 * 60 * 60 * 1000)
  wrapper.querySelector("label").textContent = source.dataset.confirmDatetimeLabel || "Data e ora"
  wrapper.querySelector(".conferma-aiuto").textContent = source.dataset.confirmDatetimeHelp || ""
  input.value = source.dataset.confirmDatetimeValue || ""
  input.min = localValue(min)
  input.max = localValue(max)
  message.hidden = true
  input.oninput = () => { message.hidden = true; input.removeAttribute("aria-invalid") }

  return {
    name,
    input,
    error() {
      if (!input.value) return "Scegli data e ora."
      const chosen = new Date(input.value)
      if (Number.isNaN(chosen.getTime())) return "La data non è valida."
      if (chosen < new Date(Date.now() + 10 * 60 * 1000)) return "Facebook programma i post solo da 10 minuti in poi."
      if (chosen > max) return "Facebook programma i post al massimo 30 giorni prima."
      return null
    },
    show(text) {
      message.textContent = text
      message.hidden = false
      input.setAttribute("aria-invalid", "true")
      input.focus()
    }
  }
}

// AAAA-MM-GGTHH:MM nell'ora locale, il formato dei campi datetime-local.
function localValue(date) {
  const pad = (n) => String(n).padStart(2, "0")
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

// Rinvia il form con la data scelta in un campo nascosto, senza chiedere di nuovo conferma.
function resubmitWithDate(form, name, value) {
  let hidden = form.querySelector(`input[type=hidden][name="${CSS.escape(name)}"]`)
  if (!hidden) {
    hidden = Object.assign(document.createElement("input"), { type: "hidden", name })
    form.append(hidden)
  }
  hidden.value = value
  const message = form.getAttribute("data-turbo-confirm")
  form.removeAttribute("data-turbo-confirm")
  try {
    form.requestSubmit(form.querySelector("button[type=submit], input[type=submit]") || undefined)
  } finally {
    form.setAttribute("data-turbo-confirm", message) // Turbo l'ha già letto: per il prossimo clic torna com'era
  }
}

// Nel popup del calendario la conferma a fisarmonica, altrove la finestra.
function confirmMethod(message, element) {
  const container = element?.closest?.("[data-conferma-in-linea]")
  return container ? confirmInline(message, element, container) : confirmWithDialog(message, element)
}

if (Turbo.config?.forms) Turbo.config.forms.confirm = confirmMethod
else Turbo.setConfirmMethod(confirmMethod)
