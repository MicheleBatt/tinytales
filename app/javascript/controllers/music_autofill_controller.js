import { Controller } from "@hotwired/stimulus"

// «✦ Compila con Claude» nel form della musicoteca: manda file, link e tag all'app, che chiede a Claude
// di proporre la scheda, poi riempie i campi del form. Non salva niente: la persona controlla e salva.
export default class extends Controller {
  static targets = [ "file", "url", "tags", "button", "status", "warning" ]
  static values = { url: String, trackId: Number }

  async fill() {
    const file = this.fileTarget.files[0]
    if (!file && !this.trackIdValue) return this.say("Scegli prima il file del brano: Claude lo usa per compilare la scheda.", true)

    const data = new FormData()
    if (file) data.append("audio", file)
    if (this.trackIdValue) data.append("track_id", this.trackIdValue)
    data.append("source_url", this.urlTarget.value)
    data.append("source_tags", this.tagsTarget.value)

    this.busy(true)
    this.warningTarget.hidden = true
    this.say("Claude sta analizzando il brano… di solito ci vogliono 10–20 secondi.")
    try {
      const response = await fetch(this.urlValue, {
        method: "POST", body: data,
        headers: { "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content, Accept: "application/json" }
      })
      const json = await response.json().catch(() => ({}))
      if (!response.ok || !json.fields) return this.say(json.error || "Non è stato possibile compilare la scheda: riprova.", true)

      this.apply(json.fields)
    } catch {
      this.say("L'app non risponde: controlla che sia avviata e riprova.", true)
    } finally {
      this.busy(false)
    }
  }

  apply(f) {
    this.setText("title", f.title)
    this.setText("author", f.author)
    this.setText("instruments", f.instruments)
    this.setText("suitable_for", f.suitable_for)
    this.setText("notes", f.notes)
    this.mark(this.field("license"), () => { this.field("license").value = f.license })
    this.element.querySelectorAll("input[name='music_track[moods][]'][type=checkbox]").forEach((box) => {
      box.checked = (f.moods || []).includes(box.value)
      this.mark(box.closest(".scelta"))
    })
    this.element.querySelectorAll("input[name='music_track[tempo]']").forEach((radio) => {
      radio.checked = radio.value === f.tempo
      this.mark(radio.closest(".scelta"))
    })
    const vocals = this.element.querySelector("input[type=checkbox][name='music_track[vocals]']")
    if (vocals) { vocals.checked = !!f.vocals; this.mark(vocals.closest(".scelta")) }

    if (f.discard) {
      this.warningTarget.textContent = `Claude sconsiglia questo brano: ${f.discard_reason || "non sembra adatto a una scuola dell'infanzia."}`
      this.warningTarget.hidden = false
    }
    const check = f.uncertain ? ` Da controllare ascoltandolo: ${f.uncertain}` : ""
    this.say(`Scheda compilata da Claude (i campi evidenziati): controllala prima di salvare.${check}`)
  }

  setText(name, value) {
    const input = this.field(name)
    if (!input || value === undefined || value === null) return
    input.value = value
    this.mark(input)
  }

  field(name) { return this.element.querySelector(`[name='music_track[${name}]']:not([type=hidden])`) }

  // Evidenzia per qualche secondo i campi appena compilati.
  mark(element, change) {
    if (change) change()
    if (!element) return
    element.classList.remove("compilato")
    void element.offsetWidth
    element.classList.add("compilato")
  }

  busy(on) {
    this.buttonTarget.disabled = on
    this.buttonTarget.classList.toggle("al-lavoro", on)
    this.buttonTarget.querySelector(".etichetta").textContent = on ? "Claude sta compilando…" : "Compila con Claude"
  }

  say(text, error = false) {
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("errore-campo", error)
  }
}
