# TinyTales

*Piccole storie della scuola, pronte per i social.*

App Rails, da usare in locale, per gestire i post delle pagine social della
Scuola dell'Infanzia Santa Maria Goretti di Creola: oggi la pagina Facebook, domani anche altre.

## Avvio

```bash
cd ~/Progetti/tinytales
bin/rails server -p 4500
```

Poi aprire http://localhost:4500

La prima volta, su una macchina nuova:

```bash
bin/rails db:prepare   # crea il database PostgreSQL e la pagina Facebook
```

**Attenzione:** nella shell di questa macchina è impostata una variabile `DATABASE` (per un altro progetto)
che fa fallire alcuni comandi di Rails, come `active_storage:install`, con «Invalid DATABASE provided».
In quel caso: `env -u DATABASE bin/rails …`.

## Dati

Database PostgreSQL `tinytales_development`, sul server locale con l'utente di sistema.

- **posts**: titolo, testo (`body`), data e ora di pubblicazione (`publish_at`, facoltativa nelle bozze),
  stato (`draft`, `scheduled`, `published`) e note interne (cosa manca, promemoria).
  Immagini e video sono allegati Active Storage (`media`), nell'ordine in cui vanno caricati.
- **social_pages**: le pagine social gestite (nome, piattaforma, indirizzo, id sul social e token cifrato).
  Per un nuovo social si aggiunge la piattaforma in `SocialPage::PLATFORMS` e si crea la pagina.
- **publications**: su quali pagine esce ogni post, con l'id del post sul social, i file inviati e l'ultimo errore.

I file allegati ai post e quelli delle chat con Claude stanno in `storage/` (Active Storage), fuori da git:
**database e `storage/` vanno salvati insieme** per un backup completo (per il database: `pg_dump tinytales_development`).
- **assistant_conversations** / **assistant_messages**: le chat con Claude, una per post (o per un post nuovo non ancora
  salvato). Ogni messaggio ha i suoi file (`has_many_attached :files`): gli allegati della persona, o le immagini create
  da Claude. Cancellando un post si cancellano anche la sua chat e i suoi file.

## Pagine

- **Elenco** (`/posts`): tutti i post dal più recente, prima quelli senza data. Filtri Ransack per testo
  (titolo, testo, note), stato, pagina social, intervallo di date, solo post con note, ordine.
- **Dettaglio** (`/posts/:id`): testo con il pulsante «Copia testo», note, pagine social, immagini e video.
- **Nuovo post** (`/posts/new`, pulsante «Nuovo post» nell'elenco) e **Modifica** (`/posts/:id/edit`,
  pulsante «Modifica» nel dettaglio): stessa impaginazione del dettaglio, con tutti i campi modificabili.
  La pagina Facebook è già selezionata per i post nuovi.

Nel form i file già allegati si riordinano trascinandoli o con le frecce ← → (da tastiera e da telefono),
si tolgono con «Rimuovi» (si può annullare fino al salvataggio), e i nuovi si aggiungono in coda.
L'ordine è salvato nella colonna `posts.media_order` (id dei blob), perché Active Storage non ne tiene uno:
nelle viste si usa sempre `post.ordered_media`. Il form invia l'elenco completo dei file da tenere (id firmati) seguito dai nuovi:
quelli non più elencati vengono staccati. Se il salvataggio fallisce non cambia niente, e i nuovi file
vanno scelti di nuovo.

## Stati di un post

- Ogni post **nasce bozza**. Data e ora di pubblicazione si possono lasciare vuote finché è una bozza;
  programmati e pubblicati ce l'hanno sempre. Lo stato non si cambia dal form ma dai pulsanti della pagina del post:
  - una bozza ha sempre **Pubblica Ora** e **Programma**, qualunque data abbia;
  - **Pubblica Ora** → pubblicato subito; la data diventa quella vera di uscita;
  - **Programma** → la finestra di conferma propone la data del post se è futura (altrimenti va scelta),
    da 10 minuti a 30 giorni da adesso; programmato a quella data, che diventa la data del post
    (salvata solo se Facebook accetta);
  - il bottone blu è Programma se la bozza ha già una data futura, altrimenti Pubblica Ora;
  - post pubblicato → **Spubblica** → di nuovo bozza.
- Il server ricontrolla l'ora al momento del clic (`Post#publish!`, `#schedule!`, `#unpublish!`).
- Un post si può sempre **modificare** ed **eliminare** (con conferma), in qualunque stato.

## Collegamento con i social

Ogni azione sul post vale anche sulle sue pagine social (oggi solo Facebook, con le Graph API di Meta):

| Nell'app | Su Facebook |
|---|---|
| **Pubblica** | il post viene pubblicato subito |
| **Programma** | il post viene programmato (Facebook accetta da 10 minuti a 30 giorni da adesso) |
| **Modifica** di un post programmato | viene ricreato con testo, file e ora nuovi, poi il vecchio viene tolto |
| **Modifica** di un post pubblicato | viene aggiornato il testo; foto e video Facebook non li lascia cambiare (l'app avvisa) |
| **Spubblica** | il post viene cancellato da Facebook; nell'app resta come bozza |
| **Elimina** | il post viene cancellato da Facebook e dall'app |

- Prima si chiama Facebook, poi si cambia lo stato: se Facebook rifiuta, il post resta com'era e si vede il motivo.
- Su Facebook un post può avere più foto oppure un solo video, non entrambi.
- Le pagine social di un post già programmato o pubblicato non si cambiano dal form: va prima spubblicato.
- I post programmati diventano «pubblicati» nell'app quando passa la loro ora (Facebook li pubblica da sé).
- I post pubblicati a mano su Facebook, fuori dall'app, non sono collegati: l'app non li può modificare né togliere
  (Facebook permette di modificare solo i post creati dalla stessa app), e lo segnala.
- Il codice: `PostSync` (cosa fare sui social per ogni azione), `SocialPublishers::Facebook` (le chiamate),
  `FacebookGraph::Client` (HTTP). Per un nuovo social basta un altro publisher in `SocialPublishers.for`.

### Collegare la pagina Facebook (una volta sola)

Serve un'app Meta tua, **in modalità Live**: in modalità sviluppo i post pubblicati dall'app li vede solo chi ha
un ruolo sull'app. Basta l'accesso standard, senza revisione di Meta, perché sei tu a gestire la pagina.

1. Su [developers.facebook.com](https://developers.facebook.com/), con l'account Facebook che gestisce la pagina:
   **Le mie app → Crea app**. Caso d'uso: gestione di una Pagina (*Manage everything on your Page*).
   Per passare in Live servono l'URL dell'informativa sulla privacy, una categoria e un'icona.
2. In **Impostazioni app → Di base** copia l'**ID app** e la **chiave segreta**.
3. Apri il [Graph API Explorer](https://developers.facebook.com/tools/explorer/), scegli l'app, poi
   **Token d'accesso utente** con i permessi `pages_show_list`, `business_management`, `pages_read_engagement`,
   `pages_manage_posts` e `read_insights` (quest'ultimo serve per le statistiche dei post).
   `public_profile` Facebook lo aggiunge da sé. Servono **tutti**: un token senza uno di questi lo perde.
   `publish_video` non è disponibile, ma non serve: i video si pubblicano lo stesso.
   Nella finestra di Facebook seleziona la pagina della scuola. Copia il token generato.
4. Nel terminale:
   ```bash
   cd ~/Progetti/tinytales
   env -u DATABASE bin/rails social:facebook:connect   # chiede ID app, chiave segreta e token (questi due non compaiono a schermo)
   env -u DATABASE bin/rails social:facebook:check     # verifica: deve stampare il nome della pagina
   ```

L'app salva solo il token della pagina, **cifrato** nel database (le chiavi sono nelle credenziali di Rails,
protette da `config/master.key`, che non va mai condiviso né messo in git). ID app e chiave segreta non vengono salvati.
Il token della pagina non scade da solo, ma smette di funzionare se cambi la password di Facebook, perdi l'accesso
alla pagina o rimuovi l'app: in quel caso basta rifare `social:facebook:connect`.

La versione delle Graph API è `v26.0`; si cambia con la variabile `FACEBOOK_GRAPH_VERSION`.

### Statistiche dei post (visualizzazioni e persone raggiunte)

Per ogni post pubblicato l'app salva le **visualizzazioni** (`post_media_view`) e le **persone raggiunte**
(`post_total_media_view_unique`) nella tabella `publication_metrics`. C'è una riga per pubblicazione e per giorno
(`measured_on`, in ora italiana), aggiornata a ogni lettura del giorno con l'ora esatta (`measured_at`). I numeri sono totali
dalla pubblicazione, perché Facebook non dà il dettaglio giorno per giorno. Quelli di un giorno li calcolano
`PublicationMetric#daily_views` e `#daily_reach` come differenza con il giorno letto prima, ma non se il post nel frattempo
è stato ripubblicato (`remote_id` diverso). Le righe sono legate alla pubblicazione, quindi a una pagina social precisa:
quando un post uscirà anche su altri social, ognuno avrà le sue.

- **Dove si vedono** (solo per i post pubblicati):
  - elenco a **lista**: colonna «Statistiche», con un'icona a occhio per le visualizzazioni e una a persone per quelle raggiunte;
  - elenco a **griglia**: le stesse icone e gli stessi numeri in un'etichetta chiara e discreta sopra la copertina;
  - **pagina del post** e **popup del calendario**: due riquadri «VISUALIZZAZIONI» e «PERSONE RAGGIUNTE» sotto lo stato,
    con il totale e l'aumento dall'ultimo giorno letto prima («+69 dal 26 nov», `PostStats.change`); in fondo due grafici
    dell'andamento nei giorni di lettura, ognuno nel suo riquadro (`TrendChart`, SVG disegnato sul server);
  - **report PDF**: gli stessi riquadri e grafici nella pagina di ogni post pubblicato.
- **Ordinamento:** nel filtro «Ordine» dell'elenco ci sono anche «Più/Meno visualizzazioni» e «Più/Meno persone raggiunte»
  (`s=views desc`, `s=reach asc`…: scope `Post.sort_by_views_desc` e simili, che Ransack usa da solo). Conta il totale
  salvato all'ultima lettura; i post senza numeri, come le bozze, vanno in fondo in entrambi i versi.
- **Quando si leggono:** le pagine si aprono subito con i numeri salvati; poi il browser chiede quelli aggiornati
  (controller Stimulus `stats-refresh` → `GET /posts/statistiche?ids=…&contesto=elenco|pagina|popup`, `PostsController#stats`).
  L'app li legge dai social e risponde con un Turbo Stream che sostituisce sul posto numeri e grafici.
  Il report PDF invece li aggiorna prima di generarsi, aspettando le risposte.
- **Grafici:** l'asse del tempo è proporzionale (i giorni senza lettura restano spazi) e le date si diradano da sole
  (ogni giorno, ogni 2/3/7/14 giorni, poi ogni 1/2/3/6/12 mesi) per non sovrapporsi. L'asse dei valori parte da zero
  con tacche tonde. I pallini su ogni lettura compaiono solo se sono pochi e ben distanziati; il valore finale è scritto
  in fondo alla linea. Al passaggio del mouse compaiono una linea guida e un suggerimento con data e valore.
- **Come:** tutte le letture partono in una sola richiesta (batch di Facebook, fino a 50 post; oltre, più richieste in parallelo).
  Per un video (reel) le statistiche stanno sul post che lo contiene: l'app chiede una volta il suo id e lo salva in
  `publications.remote_post_id`.
- **Limiti di Meta** (con il token della pagina: 4.800 chiamate ogni 24 ore × le persone che hanno interagito con la pagina;
  ogni post letto conta come una chiamata, anche dentro la batch):
  - un post letto da meno di un minuto non si rilegge (`PostMetrics::FRESH_FOR`);
  - se Facebook dice che l'uso ha raggiunto il 75% del limite, la pagina non viene interrogata per 15 minuti; se risponde
    «troppe chiamate» (errore 80001 o simili), per almeno 30, o di più se Meta stima un'attesa maggiore
    (`social_pages.metrics_paused_until`);
  - gli errori non bloccano mai le pagine né il report: restano i numeri salvati, e il problema finisce nel log
    (righe `[statistiche Facebook]`).
- **Codice:** `PostMetrics` (cosa leggere e quando frenare), `SocialMetrics::Facebook` (la lettura vera), `PostStats`
  (totali e andamento sommati sui social), `TrendChart` e `PostStatsHelper` (grafici, icone e numeri),
  `FacebookGraph::Client#batch` e `FacebookGraph::Usage` (l'uso dei limiti dalle intestazioni delle risposte).

## Assistente (Claude Code) nelle pagine di creazione e modifica

A destra del form c'è una chat con **Claude Code**, installato su questa macchina (`~/.local/bin/claude`).
Si apre e si chiude con «×» e «✦ Claude», e il browser ricorda la scelta. Il testo di Claude compare
lettera per lettera; i puntini animati compaiono solo nelle pause, cioè mentre Claude ragiona o usa
uno strumento e in chat non sta comparendo niente. La conversazione si salva
nel database, una per post, e si ritrova riaprendo il post. Quella di un post nuovo gli resta legata quando lo salvi.

- **Contesto:** Claude parte dalla cartella del sito, quindi carica memoria e convenzioni del progetto,
  e vede anche l'app. A ogni messaggio riceve lo stato attuale del form, anche se non è ancora salvato.
- **Proposte:** Claude non modifica mai il post. Risponde con blocchi ```` ```proposta:titolo ````, `testo`,
  `note`, `data` e `file`, che nella chat diventano riquadri con il pulsante **«Applica al form»**, o
  «Aggiungi al post» per i file. Poi si salva come sempre.
- **Permessi** (in `AssistantRunner#command`):
  - **Lettura:** solo file di sito, app e memoria del progetto. Sono vietati i segreti dell'app (`config/*.key`,
    `config/credentials*`, `.env*`) e tutto ciò che sta fuori da quelle tre cartelle (`AssistantRunner#outside_paths`),
    anche per Grep e Glob.
  - **Scrittura:** solo nella cartella di lavoro, `tmp/assistant/<token>/` (o `tmp/proposte/<token>/` per le proposte).
  - **Comandi:** da Bash solo ImageMagick (`convert`, `magick`, `montage`, `composite`, `identify`) e
    `bin/assistant posts` / `bin/assistant post ID`, che leggono il database senza modificarlo.
    ImageMagick gira con regole proprie (`tmp/imagemagick/<token>/policy.xml`, generate a ogni avvio): legge solo sito,
    risorse e file dei post, non trasforma file di testo in immagini e scrive solo nella cartella di lavoro.
  - **Isolamento:** Claude parte senza nessuna impostazione esterna (`--setting-sources ""`: né i permessi accumulati
    nelle impostazioni di Claude Code del sito o della home, né hook o plugin), senza i connettori MCP dell'account
    (`--strict-mcp-config`), con i soli strumenti Read, Glob, Grep, Edit, Write e Bash (`--tools`: niente web,
    sotto-agenti o skill) e con un ambiente ridotto alle variabili indispensabili (`AssistantRunner#claude_env`:
    nessuna chiave o password di altri progetti).
  - **Escluso:** niente git, niente modifiche a sito o app, niente pubblicazione sui social.
- **Allegati:** con «📎 Allega», o trascinandoli sulla chat, si mandano a Claude testi (`.txt`, `.md`, `.csv`), PDF,
  immagini e video, fino a 10 file per messaggio e 100 MB ciascuno. Si salvano sul messaggio e, durante la risposta, stanno nella cartella di lavoro;
  Claude legge testi, PDF e immagini e può proporre immagini e video per il post. Niente Word: va copiato il testo
  o salvato in PDF. Se un file non va bene, il messaggio non parte e non resta niente.
- **File della chat:** Claude lavora su file veri. Prima di ogni risposta la cartella di lavoro `tmp/assistant/<token>/`
  viene preparata con i file già salvati della chat (così Claude può riprendere e modificare un'immagine di prima);
  dopo la risposta le immagini nuove o modificate si salvano sul messaggio di Claude e la cartella si svuota.
  Script e file intermedi (con il prefisso `_`) non si conservano. Pulizia delle chat di post nuovi mai salvati:
  `bin/rails assistant:cleanup` (quelle ferme da più di 14 giorni; `GIORNI=30` per cambiare).
- **Cosa sa fare:** testi; grafiche composte con ImageMagick da foto, logo e locandine della scuola
  (17 font liberi di Google Fonts in `lib/assistant/risorse/font/`, logo in `lib/assistant/risorse/`).
  Unico vincolo di stile: un tono vivace e gioioso, adatto a una scuola dell'infanzia; per il resto le grafiche
  devono variare da un post all'altro. Non genera fotografie né video.
- **Istruzioni** che riceve Claude: `lib/assistant/istruzioni.md`.
- **Tecnica:** `POST /assistente/messaggi` risponde in streaming (`ActionController::Live`, una riga JSON
  per evento). `AssistantRunner` lancia `claude -p --output-format stream-json` e riprende la sessione
  con `--resume`. Il controller Stimulus `assistant` mostra la risposta e applica le proposte.
- Ogni messaggio usa l'abbonamento Claude Code di chi è collegato su questa macchina.

## Test

```bash
env -u DATABASE bin/rails test
```
