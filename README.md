# Kit d'arrencada

**En una frase:** un sol script que et deixa a punt per treballar al teu producte. Comprova i instal·la el que falta, instal·la Gentle Shell, inicia sessió a GitHub, clona el teu repositori i l'obre.

> El comentari de l'alta de producte indica l'URL del repositori; el nom `ORGANITZACIO/nom` surt d'aquesta URL. (L'ordre del kit dins d'aquest comentari encara està pendent.)

## Com s'executa

| Sistema | Com |
|---|---|
| **Windows** | Doble clic a `windows/arrencada.cmd`; el repositori (`ORGANITZACIO/nom`) te'l demana el propi PowerShell |
| **macOS** | Doble clic a `unix/arrencada.command` i escriu `ORGANITZACIO/nom` quan t'ho demani |
| **Linux** | `sh unix/arrencada.sh --repo ORGANITZACIO/nom` |

Es pot tornar a executar tantes vegades com calgui: el que ja està fet se salta.

## Què fa

| Pas | Què | Windows | macOS / Linux |
|---|---|---|---|
| 1 | Git, GitHub CLI (`gh`), Node.js 24 o superior | **Ho instal·la IT** (NinjaOne). Si falta, l'script s'atura i t'ho diu | `gh` i Node s'instal·len a la teva carpeta (`~/.local`), sense permisos d'administrador. Git: macOS obre l'instal·lador d'Apple; a Linux cal instal·lar-lo amb el gestor de paquets |
| 2 | Gentle Shell (amb Engram local) | Instal·lador oficial, amb el checksum SHA-256 comprovat | Igual |
| 3 | Sessió de GitHub | `gh auth login` al navegador. **Mai** has de copiar cap token | Igual |
| 4 | Nom i correu de Git | Només si no estan configurats. El correu ha de ser corporatiu | Igual |
| 5 | Clonar el repositori | A `~/projectes/<nom>` | Igual |
| 6 | Dependències | `npm ci` (o `npm install` si el projecte no té `package-lock.json`) | Igual |
| 7 | Obrir Gentle Shell | A la carpeta del projecte. Prova `/gentle:guide` | Igual |

## Opcions

| Opció (sh) | Opció (PowerShell) | Per a què |
|---|---|---|
| `--repo ORG/NOM` | `-Repo ORG/NOM` | Repositori (obligatori) |
| `--directori DIR` | `-Directori DIR` | Carpeta diferent de `~/projectes/<nom>` |
| `--correu EMAIL` | `-Correu EMAIL` | Correu de Git sense que te'l pregunti |
| `--no-obrir` | `-NoObrir` | No obre Gentle Shell al final |
| `--sense-gentle-shell` | `-SenseGentleShell` | No instal·la Gentle Shell |

Dominis de correu permesos: variable `ARRENCADA_DOMINIS` (separats per espais; per defecte `fedefarma.com`).

Instal·lació de requisits a macOS/Linux: variable `ARRENCADA_INSTALAR_PREREQUISITS`. `1` (per defecte) instal·la `gh` i Node a `~/.local`; `0` no instal·la mai res i s'atura amb el codi 10 (com a Windows) perquè ho resolgui IT.

## Si alguna cosa falla

| Codi | Què vol dir | Què fer |
|---|---|---|
| 10 | Falta un requisit que no pots instal·lar tu (o la instal·lació automàtica està desactivada) | Windows: demana-ho a IT. Mac: acaba l'instal·lador d'Apple i torna-ho a executar. Linux: instal·la Git |
| 11 | Una descàrrega no ha superat la comprovació de seguretat | Torna-ho a provar; si es repeteix, avisa Plataforma. **No** ho instal·lis a mà |
| 12 | Gentle Shell no ha acabat d'instal·lar-se | Acaba l'assistent del navegador i torna a executar el kit |
| 13 | No s'ha pogut iniciar sessió a GitHub o no tens accés al repo | Demana accés a Plataforma |
| 64 | Dades d'entrada incorrectes | Revisa el nom del repositori, la carpeta o el correu |

> ⚠️ **Mai** enganxis contrasenyes, tokens ni claus al terminal, al xat o al repositori. Si passa, canvia-les i avisa Plataforma.

---

## Per a IT

La documentació per a IT (prerequisits a Windows i polítiques que poden bloquejar el kit) és al repositori intern `alta-productes`, a `docs/kit-arrencada-it.md`.

### Seguretat

- El kit **no conté credencials**. GitHub s'autentica al navegador.
- Només descarrega de `github.com`, `nodejs.org` i dels servidors de descàrrega de GitHub (host exacte, sempre HTTPS); les URL alternatives només funcionen en mode de prova. **Comprova el SHA-256** amb els fitxers oficials de cada projecte. Si no coincideix, esborra la descàrrega i s'atura.
- Al Mac i Linux mai fa servir `sudo` ni Homebrew.

### Estat

| Part | Provada |
|---|---|
| `unix/arrencada.sh` (macOS) | ✅ Tests automàtics i execució real (clonar + `npm ci`); descàrrega real de `gh` i Node amb verificació |
| `unix/arrencada.sh` (Linux) | Tests automàtics; sense execució real |
| `windows/*.ps1` / `.cmd` | ⚠️ **Sense executar**. Cal provar-ho en un Windows gestionat amb un usuari estàndard |

## Desenvolupament

```bash
npm test                                       # tests del script sh (Node 24, sense dependències)
shellcheck -s sh unix/arrencada.sh unix/arrencada.command
```
