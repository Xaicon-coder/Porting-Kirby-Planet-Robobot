# PlanetPort

App iOS nativa per giocare al **tuo** dump di *Kirby: Planet Robobot* su iPhone e iPad, con
multiplayer. Funziona con qualsiasi gioco 3DS, ma l'interfaccia è pensata per Planet Robobot.

PlanetPort non contiene la ROM, chiavi, firmware o grafica Nintendo. Il gioco lo aggiungi tu
dall'app, dopo averlo estratto dalla tua console e dalla tua cartuccia.

## Come funziona

Un vero "porting" del codice sorgente di Planet Robobot non è possibile: il sorgente non è
pubblico e non esiste una decompilazione. PlanetPort fa la cosa più vicina che si può fare in
modo legale:

- **Interfaccia nativa iOS** in SwiftUI e UIKit: libreria giochi, controlli touch multitocco,
  controller Bluetooth, giroscopio, salvataggi rapidi, menu di pausa.
- **Core di emulazione Azahar** (il successore open source di Citra), integrato come framework
  nativo `PlanetCore`. Il codice ARM del gioco viene eseguito dal JIT Dynarmic quando iOS lo
  permette, altrimenti dall'interprete veloce di Azahar.
- **Grafica Vulkan su Metal** tramite MoltenVK, con risoluzione interna fino a 6x.
- **Multiplayer** tramite le stanze di rete di Azahar, che emulano il wireless locale del 3DS.
  È quello che usa la modalità Team Kirby Clash di Planet Robobot.

I dettagli tecnici sono in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Cosa ti serve

- Un **Mac** con Xcode 16 o successivo. iOS si compila solo su macOS.
- [Homebrew](https://brew.sh) con gli strumenti di build.
- Un **iPhone o iPad** con iOS 16 o successivo. Le build per il simulatore non sono supportate.
- Un **Apple ID**. Quello gratuito basta, ma l'app va reinstallata ogni 7 giorni.
- Una **console 3DS** con la tua copia di Kirby: Planet Robobot, per fare il dump.

Installa gli strumenti:

```bash
brew install cmake ninja xcodegen git python
```

## Compilare l'app

Dalla cartella del progetto lancia:

```bash
bash scripts/bootstrap.sh
```

Lo script esegue quattro passi:

1. Scarica Azahar al commit verificato (`12bde376`) con tutti i sottomoduli, in `third_party/azahar`.
2. Applica le patch per iOS con `scripts/patch_azahar.py`. Se una patch non trova il punto
   esatto, lo script si ferma.
3. Compila il core e il bridge per `iphoneos arm64` e produce `build/PlanetCore.framework`.
   La prima compilazione richiede da 20 a 40 minuti.
4. Genera il progetto Xcode `App/PlanetPort.xcodeproj` con XcodeGen.

Poi in Xcode:

1. Apri `App/PlanetPort.xcodeproj`.
2. Seleziona il target **PlanetPort**, scheda *Signing & Capabilities*, e scegli il tuo **Team**.
   Se Xcode segnala il bundle id come già usato, cambia `org.planetport.app` con un valore tuo.
3. Collega l'iPhone, selezionalo come destinazione e premi **Run**.

Se modifichi solo il codice Swift non serve ricompilare il core. Dopo una modifica al bridge
Objective-C++ ricompila il framework con:

```bash
bash scripts/build_core.sh --no-fetch
```

Se cambi il commit di Azahar in `scripts/fetch_azahar.sh`, aggiungi `--force` per ripartire da
un sorgente pulito.

## Installare senza Mac (da Windows)

Non serve avere un Mac. GitHub compila l'app su un Mac virtuale a ogni modifica del repository,
gratis per i repository pubblici. La prima compilazione dura circa un'ora; le successive sono più
rapide grazie alla cache.

1. Nel repository GitHub apri **Releases** e scarica `PlanetPort.ipa` dalla release *latest*.
   La stessa build è anche nella scheda **Actions**, tra gli *Artifacts* dell'ultima esecuzione.
2. Sul PC installa iTunes e iCloud scaricati dal sito Apple, non quelli del Microsoft Store, e
   poi [Sideloadly](https://sideloadly.io).
3. Sull'iPhone attiva *Impostazioni > Privacy e sicurezza > Modalità sviluppatore* e riavvia.
4. Collega l'iPhone via USB, trascina `PlanetPort.ipa` in Sideloadly, inserisci il tuo Apple ID
   e premi **Start**. Con un Apple ID gratuito l'app va reinstallata ogni 7 giorni; Sideloadly
   può rinnovarla da solo quando l'iPhone è collegato.
5. Al primo avvio iOS chiede di fidarsi dello sviluppatore: *Impostazioni > Generali > VPN e
   gestione dispositivi*.

Se una compilazione fallisce, la scheda **Actions** mostra l'errore e l'artifact *build-logs*
contiene i log completi.

## Preparare il gioco

Azahar avvia solo giochi **decriptati**. Il dump si fa con GodMode9 sulla tua 3DS con firmware
modificato:

1. Inserisci la cartuccia di Planet Robobot e avvia GodMode9.
2. Apri `[C:] GAMECART`, premi A sul file `.trim.3ds` e scegli **NCSD image options** e poi
   **Decrypt file (…)**. In alternativa scegli **Build CIA from file**.
3. Il file decriptato finisce in `/gm9/out/` sulla scheda SD. Copialo sul Mac o su iCloud Drive.

Gli aggiornamenti e i DLC si installano come `.cia` decriptati, sempre dall'app.

Per importare il gioco hai due strade:

- **Dall'app.** Tocca **Importa** e scegli il file `.3ds`, `.cci`, `.cxi` o `.cia`. I `.cia`
  vengono installati nella scheda SD emulata.
- **Dall'app File.** Apri *Sul mio iPhone*, poi *PlanetPort*, di nuovo *PlanetPort* e infine
  *games*, e trascina lì il file. L'app lo trova al successivo aggiornamento della lista, che si
  fa tirando giù l'elenco dei giochi.

## JIT: velocità piena

iOS permette di generare codice eseguibile, cioè il JIT, solo se all'app è collegato un
debugger. Senza JIT PlanetPort usa l'interprete di Azahar. Funziona sempre, ma è più lento: sui
dispositivi recenti Planet Robobot può girare sotto la velocità piena.

Per attivare il JIT:

1. Installa l'app con SideStore oppure con Xcode.
2. Avvia PlanetPort tramite **StikDebug** o la funzione *Enable JIT* di SideStore. Anche avviarla
   da Xcode con il debugger collegato funziona.
3. Nella schermata principale compare l'indicatore verde **JIT attivo**.

Su iOS 26, con i chip dotati di TXM, il metodo di attivazione del JIT può non funzionare.
PlanetPort lo verifica all'avvio e, se serve, torna da solo all'interprete invece di bloccarsi.

## Multiplayer

La modalità Team Kirby Clash usa il wireless locale del 3DS. PlanetPort lo emula con le stanze di
Azahar. Ogni giocatore deve avere **la propria copia** del gioco nella propria app.

**Sulla stessa rete Wi-Fi:**

1. Un giocatore apre **Multiplayer** e tocca **Ospita una stanza**, con 4 giocatori.
2. Gli altri vedono la stanza in **Stanze nella tua rete Wi-Fi** e la toccano per entrare.
3. Tutti avviano il gioco e scelgono la modalità multigiocatore locale di Team Kirby Clash.

Il primo collegamento fa comparire la richiesta di accesso alla rete locale di iOS: va
accettata.

**Via Internet** ci sono due opzioni:

- **Port forwarding.** Chi ospita apre la porta **UDP 24872** sul router e comunica il proprio
  IP pubblico. Gli altri usano **Connettiti a un indirizzo**.
- **VPN mesh.** Più semplice e senza toccare il router: tutti installano Tailscale o ZeroTier e
  usano l'indirizzo VPN di chi ospita.

**Errori comuni:**

| Messaggio | Soluzione |
|---|---|
| Nome già in uso | Cambia il nome giocatore in *Multiplayer* (da 4 a 10 caratteri) |
| ID console duplicato | *Impostazioni*, sezione *Console*, poi **Rigenera ID console** |
| Indirizzo MAC duplicato | *Impostazioni*, sezione *Console*, poi **Rigenera indirizzo MAC** |
| Impossibile connettersi | Controlla IP e porta, la stessa rete Wi-Fi o il port forwarding |

L'app va tenuta in primo piano: iOS sospende la rete delle app in background. I salvataggi
rapidi non si possono caricare mentre sei in una stanza: è un limite di Azahar.

## Controlli

| 3DS | Touch | Controller |
|---|---|---|
| Circle Pad | levetta a sinistra | levetta sinistra |
| Croce direzionale | opzionale, al posto della levetta | croce |
| A B X Y | rombo a destra | tasti frontali, per posizione o per etichetta |
| L / R | angoli in alto | dorsali |
| ZL / ZR | piccoli, accanto a L/R | grilletti |
| START / SELECT | in basso al centro | Menu / Opzioni |
| Schermo inferiore | tocca direttamente lo schermo | — |
| Giroscopio | movimento dell'iPhone | — |

Con un controller collegato i comandi touch si nascondono. Puoi cambiare questo comportamento
nelle impostazioni.

## Cosa è stato verificato

Il progetto è stato scritto confrontando ogni chiamata con il sorgente di Azahar al commit
fissato. **Non è ancora stato compilato né provato su un dispositivo**, perché è stato preparato
su Windows senza Xcode. Alla prima compilazione su Mac aspettati qualche correzione minore.
I punti più delicati sono:

- il collegamento statico di MoltenVK nel framework, incluse le eventuali librerie di sistema
  mancanti;
- le patch al core, che `patch_azahar.py` verifica in modo esatto;
- la conversione degli assi del giroscopio.

## Struttura

```
PlanetPort/
  scripts/            bootstrap, download, patch e compilazione del core
  core-bridge/        framework PlanetCore (Objective-C++), API pubblica in include/PlanetCore
  App/                app SwiftUI (project.yml per XcodeGen)
  docs/               architettura e contratto delle API Swift
```

## Licenza e marchi

PlanetPort è software libero sotto **GPLv2 o successiva**, la stessa licenza di Azahar, che
include e collega. Componenti di terze parti:

- Azahar e Citra (GPLv2+)
- MoltenVK (Apache 2.0)
- Dynarmic e oaknut (BSD/MIT)
- OpenAL Soft (LGPL)

Kirby, Nintendo 3DS e i relativi marchi appartengono a Nintendo. PlanetPort non è affiliato a
Nintendo né ad HAL Laboratory. Usa solo giochi che possiedi e di cui hai fatto il dump tu.
