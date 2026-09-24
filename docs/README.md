# Guía de uso de Rocky

Última actualización: 2026-09-24

Rocky es una app de macOS para trabajar con agentes de código (Claude Code y OpenCode) en paralelo. Cada tarea vive
en su propio workspace, con su propia copia del repositorio, así que varios agentes pueden trabajar a la vez sin
pisarse. La idea viene de Conductor.

**Estado de esta guía.** Describe lo construido de M1 a M2.7:

- M2.7 (el panel de GitHub) está construido y en verificación en la rama `feat/m2.7-github`.
- M2.6 (los comandos con "/" y la tecla Esc dentro de un terminal) ya está en `development`. La rama de M2.7 lo
  recibe cuando se una con `development`, un paso que su plan tiene pendiente. Si compilas `feat/m2.7-github`
  antes de esa unión, esas dos cosas todavía no están.

---

## 1. Conceptos básicos

| Término | Qué es en Rocky |
| --- | --- |
| Repositorio | Una carpeta con un repositorio de git que agregas a Rocky. Rocky la llama el "clon principal". |
| Workspace | Un espacio de trabajo para una tarea. Tiene su propia carpeta, su propia rama, sus conversaciones y sus terminales. |
| Worktree | La copia de trabajo de git que usa cada workspace (`git worktree`). Comparte el historial con el clon principal, pero tiene sus propios archivos. |
| Agente | El programa que escribe código: Claude Code u OpenCode. Rocky habla con él por ACP (Agent Client Protocol). |
| Conversación | Un chat con un agente dentro de un workspace. Un workspace puede tener varias, cada una en su pestaña. |
| Turno | Lo que hace el agente desde que le envías un mensaje hasta que termina de responder. |

La interfaz de Rocky está en inglés. Esta guía escribe los nombres de botones y menús tal como aparecen en pantalla,
por ejemplo "Create PR" u "Open terminal".

---

## 2. Instalar y abrir

### Requisitos

- macOS 15 o superior.
- Xcode 27, con su componente Metal Toolchain (lo necesita el terminal integrado).
- `git`, y `node` con `npm` en el `PATH` de tu shell de inicio de sesión. Rocky usa `npm` para instalar sus agentes.
- `gh` (GitHub CLI) con al menos una cuenta iniciada, si quieres usar el panel de GitHub.

### Construir la app

```
scripts/make-app.sh      # construye build/Rocky.app en modo release
open build/Rocky.app
```

`scripts/make-app.sh debug` construye en modo debug. Cada vez que reconstruyas, cierra Rocky y ábrelo de nuevo.

### Certificado "Rocky Local" (una sola vez)

Rocky guarda los secretos de cada repositorio en el Llavero (Keychain) de macOS. El Llavero reconoce una app por su
firma. Si firmas siempre con el mismo certificado, cada nueva compilación es "la misma app" y el Llavero no vuelve a
pedir permiso para cada secreto.

1. Abre Acceso a Llaveros: `open -a "Keychain Access"`.
2. Ve a Keychain Access → Certificate Assistant → Create a Certificate…
3. Nombre `Rocky Local`, Identity Type `Self Signed Root`, Certificate Type `Code Signing`. Pulsa Create.
4. Comprueba que existe: `security find-identity -p codesigning` debe listar `"Rocky Local"`.

La primera vez que corras `scripts/make-app.sh` después de esto, macOS pregunta si `codesign` puede usar la llave:
elige Always Allow. Si `codesign` dice que la identidad no es de confianza, abre el certificado en Acceso a Llaveros →
Trust → Code Signing: Always Trust.

Sin el certificado, el script firma "ad hoc" y avisa. La app funciona, pero macOS vuelve a pedir cada secreto después
de cada compilación. Para usar otro certificado, define `ROCKY_SIGN_IDENTITY` con su nombre.

### Dónde guarda Rocky sus cosas

| Ruta | Qué contiene |
| --- | --- |
| `~/Library/Application Support/Rocky/rocky.sqlite` | La base de datos: repositorios, workspaces y conversaciones. |
| `~/Library/Application Support/Rocky/agents` | Los agentes que instala Rocky: el adaptador de Claude y OpenCode. |
| `~/Library/Application Support/Rocky/opencode-data` | Los datos propios del OpenCode de Rocky: sesiones y login. |
| `~/Library/Application Support/Rocky/ci-logs` | Los logs de CI que "Fix errors" adjunta, una carpeta por workspace. |
| `~/Library/Logs/Rocky` | Los logs de los agentes (lo que cada uno escribe en stderr). |
| Llavero de macOS | Los valores de las variables marcadas como secretas. |

En Settings → Data puedes abrir la base de datos y los logs en Finder.

---

### La ventana

- La primera vez Rocky abre en 1440 × 900 puntos, o lo que quepa en tu pantalla.
- Después recuerda el tamaño y la posición en que la dejaste.
- El tamaño mínimo es 900 × 560, que es lo justo para el sidebar, una conversación legible y el panel derecho lado a lado.

## 3. Repositorios y workspaces

### Agregar un repositorio

1. Pulsa "Add repository" al pie de la barra lateral.
2. Elige la carpeta raíz del repositorio y pulsa "Add".

Rocky solo acepta la raíz de un repositorio de git. Si eliges una subcarpeta, dice "… is not the root of a git
repository.". Cada repositorio recibe un color al azar para su monograma (la letra inicial en la barra lateral).
Rocky elige entre los colores menos usados por tus otros repositorios y lo guarda, así que no cambia entre sesiones.

### Crear un workspace

Pulsa el "+" junto al nombre del repositorio, usa "New Workspace" en su menú "…", o pulsa ⌘N. Rocky:

1. Hace `git fetch origin` en el clon principal.
2. Elige un nombre de ciudad libre (`lima`, `kyoto`, `oslo`…). Si todas están tomadas, añade un número (`lima-2`).
3. Crea un worktree en `<repo>-worktrees/<ciudad>`, al lado del repositorio, en la rama nueva `rocky/<ciudad>`. La
   rama sale de la rama principal de `origin` (o de la rama actual si no hay `origin`).
4. Enlaza los archivos de entorno del clon principal (sección 4).
5. Corre el script Setup, si hay uno (sección 5).

Ejemplo: para `~/Documents/dev/personal/rocky`, el workspace `lima` vive en
`~/Documents/dev/personal/rocky-worktrees/lima`, en la rama `rocky/lima`.

⌘N crea el workspace en el repositorio del workspace seleccionado, o en el primero de la lista.

### La barra lateral

- **Buscar:** ⌘K pone el cursor en el campo "Search" (y muestra la barra si estaba oculta). Filtra por título, rama,
  nombre del workspace o nombre del repositorio.
- **Plegar un repositorio:** haz clic en su nombre. Plegado, muestra el estado más urgente de sus workspaces.
- **Elegir un workspace:** clic, o ⌘1 a ⌘9 para los nueve primeros visibles. Si mantienes ⌘ presionado un momento,
  cada fila muestra su atajo. Con la lista enfocada, ↑ y ↓ mueven la selección.
- **Mostrar u ocultar la barra:** ⌃⌘S, o el botón junto a los botones de la ventana.
- **Ancho:** arrastra la línea entre la barra y el workspace.

Cada fila tiene un ícono de estado. Si aplican varios, gana el primero de esta tabla:

| Estado | Ícono | Cuándo aparece |
| --- | --- | --- |
| Needs you | Punto ámbar con halo | Un agente espera tu permiso o la respuesta a una pregunta. |
| Error | Triángulo rojo | Un agente se detuvo por un error, o el Setup falló. El tooltip dice por qué. |
| Working | Círculo girando | Un turno está en curso. |
| Unread | Punto azul | Un turno terminó mientras no mirabas ese workspace. |
| Pull request | Ícono de PR de color | Hay un PR abierto o en borrador. Verde: checks pasados. Ámbar: checks corriendo o pendientes. Rojo: un check falló o hay conflictos. Gris: borrador. |
| Merged | Ícono de merge morado | El PR se fusionó. El título se ve más tenue. |
| Idle | Ícono de rama gris | Nada de lo anterior. |

El título de una fila es el de la conversación abierta más antigua del workspace, tomado de su primer mensaje. Si
todavía no hay mensajes, la fila muestra el nombre de la ciudad, más tenue. Al pasar el mouse sobre una fila
aparecen "Remove workspace" (ícono de caja) y "…". El menú "…" y el clic derecho ofrecen Open in Finder, Copy Branch
Name y Remove Workspace…

### La barra superior y el menú Open

Arriba de la conversación ves `repositorio / rama`. Un clic en la rama la copia. El menú "Open" muestra la ruta del
worktree y ofrece:

- Open in Finder.
- Open in Antigravity, Cursor, VS Code o Zed, solo los que tengas instalados.
- New Terminal (abre un terminal en el panel inferior).
- Copy Path.

### Al abrir Rocky de nuevo

Rocky abre el último workspace que tenías seleccionado, y en cada workspace, la última conversación que mirabas.

### Quitar (archivar) un workspace

1. Pulsa "Remove workspace" en la fila, o "Remove Workspace…" en su menú.
2. Confirma con "Remove Worktree".

Rocky detiene sus agentes, terminales y scripts, corre el script Archive y borra la carpeta del worktree. **La rama
se conserva**, así que no pierdes commits. Git se niega si hay cambios sin commit, y la carpeta se queda.

Si el script Archive falla, no se borra nada. Aparece "Archive script failed" con "Remove Anyway" (quita el
workspace sin volver a correr el script) y "Cancel". La pestaña Archive muestra la salida del script.

El panel de GitHub tiene otras dos formas de archivar después de un merge (sección 11).

### Quitar un repositorio

"Remove from Rocky", en el menú "…" del repositorio, lo saca de la lista de Rocky y detiene sus procesos. Rocky no
borra carpetas ni ramas al hacerlo.

---

## 4. Archivos de entorno enlazados

Git no copia al worktree los archivos ignorados, como `.env`. Por eso Rocky los enlaza desde el clon principal al
crear un workspace, antes del Setup.

**Por defecto** enlaza estos, cuando git los lista como ignorados en el clon principal:

- `.env`, `.env.*`, `.envrc`
- `.dev.vars`, `.dev.vars.*` (secretos locales de Cloudflare Wrangler)
- `.claude/settings.local.json`

Nunca enlaza plantillas que terminan en `.example`, `.sample`, `.template` o `.dist`.

**Son enlaces simbólicos, no copias.** Cada archivo sigue teniendo un solo dueño: el clon principal. Si cambias un
secreto ahí, todos los worktrees lo ven. Si el destino ya existe en el worktree, Rocky no lo toca.

**Cambiar la lista** en los ajustes del repositorio, sección "Linked files":

- Cada valor por defecto tiene un interruptor. Apagado, se guarda como una línea `!patrón` (por ejemplo `!.envrc`).
- Para añadir una ruta o un glob, escríbelo en "Path or glob" y pulsa Return o "Add". Ejemplos: `.venv`,
  `.vscode/*`. Las rutas son relativas al repositorio. Rocky rechaza rutas absolutas, rutas con `~` y rutas fuera
  del repositorio.
- La × de una entrada la quita.

**Desde `rocky.json`**, con la clave `"links"`. Las entradas del archivo se suman a las de los ajustes. Un
`!patrón` en cualquiera de los dos apaga ese valor por defecto:

```json
{ "links": [".venv", ".vscode/*", "!.envrc"] }
```

Los cambios aplican a los workspaces nuevos. Los existentes conservan sus enlaces.

---

## 5. Scripts: Setup, Run y Archive

| Script | Cuándo corre |
| --- | --- |
| Setup | Una vez, al crear el workspace, después de enlazar los archivos de entorno. |
| Run | Cuando pulsas "Run". |
| Archive | Antes de quitar un workspace. |

Los scripts corren con zsh en la carpeta del workspace. Su salida aparece en una pestaña del panel inferior (Setup,
Run, Archive).

**El botón Run está en la barra del panel inferior**, a la izquierda de las pestañas (ya no está en la barra
superior). "▶ Run" inicia el script, selecciona su pestaña y despliega el panel. "■ Stop" lo detiene.

**Modo de Run** ("Run mode" en los ajustes del repositorio):

- "Concurrent": cada workspace puede tener su Run corriendo a la vez.
- "One at a time" (`nonconcurrent`): Run detiene primero los Run de los otros workspaces. Sirve para proyectos
  atados a un solo puerto, base de datos o stack de Docker.

Si Setup falla, el workspace queda usable y su fila muestra el estado Error. La pestaña Setup muestra el código de
salida.

### `rocky.json`

Si existe `rocky.json` en la raíz del workspace, sus scripts **reemplazan** a los de los ajustes del repositorio,
incluso si al archivo le falta alguna clave. Así el repositorio puede guardar sus scripts en git. Los `links` son la
excepción: se suman (sección 4).

```json
{
  "scripts": {
    "setup": "pnpm install",
    "run": "pnpm dev --port $PORT",
    "archive": "docker compose down"
  },
  "runScriptMode": "concurrent",
  "links": [".venv"]
}
```

`runScriptMode` acepta `"concurrent"` o `"nonconcurrent"`. Si el archivo no es JSON válido, Rocky muestra "rocky.json
is not valid: …", no corre el Setup y toma los enlaces solo de los ajustes.

### Variables que recibe cada proceso

Cada agente, terminal y script del workspace recibe:

| Variable | Valor |
| --- | --- |
| `PORT` y `ROCKY_PORT` | El primero de los diez puertos del workspace (desde 41000). |
| `ROCKY_WORKSPACE_NAME` | El nombre del workspace, por ejemplo `lima`. |
| `ROCKY_WORKSPACE_PATH` | La carpeta del worktree. |
| `ROCKY_ROOT_PATH` | La carpeta del clon principal. |
| `ROCKY_DEFAULT_BRANCH` | La rama base del workspace, por ejemplo `main`. |

Cada workspace tiene diez puertos, de `PORT` a `PORT + 9`. **La interfaz no muestra los puertos.** Solo importan a
los scripts que usan `$PORT`. Rocky no revisa si otro programa ya usa ese puerto.

### Variables del repositorio y secretos

En los ajustes del repositorio, sección "Variables", puedes añadir variables propias (nombre y valor). Marca
"Secret" para guardar el valor en el Llavero de macOS en lugar de la base de datos.

Rocky lee tu shell de inicio de sesión una vez por sesión, para que cada proceso tenga tu `PATH` y tus variables.
Si editas `~/.zshrc`, usa Rocky ▸ Refresh Shell Environment o Settings → Environment → Refresh. **Los procesos que ya
corren conservan el entorno con el que arrancaron**; los cambios aplican a los procesos nuevos.

---

## 6. Conversaciones

### Pestañas y agentes

Las conversaciones del workspace aparecen como pestañas sobre el chat. El "+" al final abre "New Claude Code
conversation" o "New OpenCode conversation". Cerrar una pestaña detiene su agente, y la conversación queda guardada.

El agente de la conversación que tienes en pantalla arranca solo, en segundo plano. Las demás arrancan cuando las
abres. Mientras arranca, el selector de modelo dice "Starting Claude Code…".

### El cuadro de mensaje

| Tecla | Qué hace |
| --- | --- |
| Return | Envía el mensaje. Si el agente está trabajando, lo pone en la cola. |
| ⇧Return o ⌥Return | Nueva línea. |
| ⇧Tab | Activa o desactiva el modo plan. |
| ⌘U | Adjunta archivos. |
| ↑ / ↓ | Recorren tus mensajes anteriores (ver abajo). |
| Esc | Detiene el turno del agente. |

### Modelo, esfuerzo y modo plan

- El botón de modelo (abajo a la izquierda) abre un menú con los modelos del agente, el esfuerzo ("Effort") y
  "Fast" cuando el agente los ofrece.
- Si el agente tiene más de ocho modelos (OpenCode lista los de todos sus proveedores), el menú muestra un buscador
  y agrupa los modelos por proveedor. Return elige el primero que coincide.
- El modo plan pide al agente que planifique antes de cambiar código. Actívalo con ⇧Tab o con "Plan mode" en el menú
  "+". Mientras está activo se ve la etiqueta "Plan". Al apagarlo, el agente vuelve al modo anterior.

### Adjuntos

- ⌘U, o "Add attachment" en el menú "+", abre el selector de archivos.
- También puedes pegar o arrastrar archivos e imágenes al cuadro.
- Cada archivo queda como una etiqueta dentro del texto, en el lugar donde lo pusiste, y el agente lo recibe en ese
  orden.
- Las imágenes van dentro del mensaje (hasta 5 MB) cuando el agente las acepta. Los demás archivos van como enlace.
- Al pasar el mouse sobre una etiqueta ves una vista previa. Un clic abre el archivo en una pestaña del workspace.

### Recuperar el último mensaje

Con el cuadro vacío, ↑ trae tu último mensaje de esa conversación, con sus archivos. ↑ otra vez trae el anterior. ↓
avanza hasta dejar el cuadro vacío. Solo funciona mientras el texto mostrado no se ha tocado; si editas, las flechas
mueven el cursor como siempre.

### Mensajes en cola

Si el agente está trabajando, Return no interrumpe: el mensaje entra en una cola y sale cuando termina el turno.

- Los mensajes en cola aparecen al final de la conversación, más tenues y con borde punteado, con la leyenda
  "Queued" o "3 queued".
- Al pasar el mouse sobre uno aparecen:
  - "Send now": detiene el turno en curso y envía ese mensaje primero.
  - "Edit": lo devuelve al cuadro para editarlo. Solo funciona con el cuadro vacío.
  - "Delete": lo borra.
- Si detienes el turno, o el agente falla, la cola queda en espera. La leyenda dice "On hold until your next message".
  Sale cuando envías otro mensaje o pulsas "Send now".
- La cola vive en memoria: si cierras Rocky, se pierde.

### Detener un turno

Pulsa Esc o el botón de detener (cuadrado). El turno termina con la marca "INTERRUPTED BY USER". También aparece
después de "Send now", porque ese botón detiene el turno en curso.

Esc va primero a lo que esté abierto encima: un menú, los ajustes o un diálogo. Solo cuando no hay nada abierto
detiene el turno.

### Preguntas y permisos del agente

- **Preguntas:** cuando el agente te pregunta algo, aparece una tarjeta sobre el cuadro de mensaje, una pregunta a
  la vez. Eliges una opción (o varias), o escribes en "Other answer". Botones: "Skip" (seguir sin responder), "Back",
  "Next" y "Submit" en la última.
- **Permisos:** cuando el agente pide permiso para una acción, aparece "Permission needed" con las opciones del
  agente y "Cancel".

En ambos casos el workspace muestra el estado "Needs you" en la barra lateral.

### Retomar conversaciones al relanzar

Rocky guarda cada conversación. Al abrirla después de relanzar, le pide al agente que retome su sesión anterior
(`session/load`), así el agente recuerda lo hablado. Si el agente ya no tiene esa sesión, Rocky muestra "Could not
resume the previous conversation (…); started a new one." (sección 15). Una conversación sin mensajes empieza una
sesión nueva sin error.

Si el agente se detiene, el cuadro de mensaje muestra el motivo y un botón "Restart".

### Pestañas de archivos

Un clic en la etiqueta de un archivo, en tus mensajes o en las acciones del agente, abre el archivo en una pestaña
junto a las conversaciones: imágenes, Markdown renderizado, texto o vista rápida de macOS.

---

## 7. Comandos con "/" (slash commands)

> Parte de M2.6, en `development` (ver "Estado de esta guía").

Escribe "/" al inicio del mensaje y aparece una lista con los comandos que anunció el agente de esa conversación:
comandos propios, skills, comandos del repositorio y prompts de servidores MCP. También puedes abrirla con "Commands"
en el menú "+".

| Tecla | Qué hace |
| --- | --- |
| ↑ / ↓ | Mueven la selección. |
| Return | Ejecuta el comando. Si el comando pide un argumento, lo completa y espera. |
| Tab | Completa el nombre, siempre. |
| Esc | Cierra la lista. |

Un "/" en medio del texto no abre la lista, porque suele ser parte de una ruta. Un mensaje que empieza con un
comando nunca le da título a la conversación.

### Comandos que se abren en un terminal

Algunos comandos de Claude Code solo funcionan en su terminal: `mcp`, `agents`, `hooks`, `memory`, `permissions` y
`plugins`. En la lista aparecen con "(opens terminal)". Rocky nunca se los envía al agente, ni a la cola.

1. Envía, por ejemplo, `/mcp`. Aparece una franja "Run /mcp in the embedded terminal" con el botón "Open terminal".
2. "Open terminal" abre un terminal sobre el cuadro de mensaje. Ahí corre el propio Claude Code de Rocky, en el
   workspace y con la instancia de Claude del repositorio.
3. Termina lo que tengas que hacer y pulsa "Done" para cerrar el terminal.
4. La franja dice "Terminal command finished. Refresh to use the updated config here". "Refresh" reinicia Claude
   Code en esa conversación, que retoma su sesión con la configuración nueva.

Esto aplica solo a conversaciones de Claude Code. En OpenCode, `/mcp` va al agente como cualquier mensaje.

---

## 8. Terminal

El panel inferior del workspace tiene pestañas para los scripts (Setup, Run, Archive) y para tus terminales.

- **Abrir un terminal:** "+" en la barra del panel, "New terminal" si el panel está vacío, u Open → New Terminal. Se
  abre tu shell de inicio de sesión en la carpeta del worktree, con las variables de la sección 5.
- **Nombres:** los terminales se llaman "Terminal 1", "Terminal 2"… según su posición.
- **Plegar y desplegar:** ⌘J, o la flecha a la derecha de la barra. Plegar no detiene nada: terminales y scripts
  siguen corriendo. Rocky recuerda si el panel estaba plegado.
- **Alto:** arrastra la línea que separa el panel del chat.
- **Estado de cada pestaña:** un punto verde mientras el proceso corre, rojo si falló. Al terminar, el terminal
  muestra una última línea como "Process exited with code 0" o "Process stopped".
- **Esc dentro de un terminal** (parte de M2.6): la tecla va al terminal, no detiene el turno del agente.

---

## 9. Avisos: sonido y número en el Dock

Rocky avisa cuando pasa algo en un workspace **que no estás mirando**:

- tienes seleccionado otro workspace, o
- la ventana de Rocky no es la ventana activa.

Avisa cuando un agente termina su turno, falla o te pregunta algo. Los avisos son:

- **Un sonido.** Se elige en Settings → Notifications → Sound, entre los sonidos de macOS. Por defecto es "Glass";
  "None" lo apaga.
- **Un número en el ícono del Dock:** cuántos workspaces te esperan. Baja cuando abres esos workspaces.

Rocky no envía notificaciones del sistema.

---

## 10. Ajustes

### Ajustes generales (⌘,)

Se abren con Rocky ▸ Settings… (⌘,) o con el engranaje al pie de la barra lateral. Es un panel sobre la ventana; Esc,
un clic fuera o la × lo cierran.

| Sección | Qué contiene |
| --- | --- |
| Appearance | Zoom: ⌘+ (o ⌘=) acerca, ⌘- aleja, ⌘0 vuelve al 100 %. Va de 80 % a 180 % en pasos de 5 % y se recuerda. |
| Notifications | El sonido de los avisos. |
| Terminal | Plegar el panel de terminal; la fuente del terminal. |
| GitHub | "Archive a workspace when its pull request merges" (apagado por defecto). |
| Environment | El shell de inicio de sesión y "Refresh" para volver a leerlo. |
| Agents | Versiones de Claude y OpenCode, la carpeta de datos de OpenCode y las actualizaciones. |
| Data | Dónde están la base de datos y los logs; cada ruta se abre en Finder. |

### Ajustes del repositorio

Se abren con "Settings…" en el menú "…" del repositorio. Save (⌘S) guarda todo; Esc, un clic fuera, la × o Cancel
cierran sin guardar.

| Sección | Qué configura |
| --- | --- |
| Scripts | Setup, Run, Archive y el modo de Run. Un `rocky.json` en el workspace los reemplaza. |
| Variables | Variables propias del repositorio; las marcadas como "Secret" van al Llavero. |
| Claude | La instancia de Claude Code (`CLAUDE_CONFIG_DIR`): "Claude default" o una carpeta `~/.claude-<nombre>` con `settings.json`. Rocky nunca toma esta variable de tu shell. |
| GitHub | La cuenta de GitHub del repositorio: "Automatic (…)" o una cuenta concreta (sección 12). |
| Linked files | Los archivos de entorno enlazados (sección 4). |

Cambiar la instancia de Claude detiene las conversaciones de Claude de ese repositorio. La que tienes en pantalla se
vuelve a abrir enseguida con la instancia nueva; las de otros workspaces, cuando las selecciones.

### Rocky administra sus propios agentes

- Rocky instala su propio adaptador de Claude (`@agentclientprotocol/claude-agent-acp`, versión 0.81.0) y su propio
  OpenCode (`opencode-ai`, versión 1.18.32) en `~/Library/Application Support/Rocky/agents`. Los instala la primera
  vez que abres una conversación de cada agente.
- Son las versiones con las que se probó Rocky. No usa el `opencode` de tu `PATH`.
- El OpenCode de Rocky tiene su propia carpeta de datos (`opencode-data`). Tu login de OpenCode se copió ahí una
  vez. Las sesiones que abras con OpenCode en un terminal no aparecen en Rocky.
- Rocky consulta npm una vez al día para ver si hay versiones nuevas, y en Settings → Agents puedes pulsar "Check
  Now". Nunca actualiza sin que pulses "Update to …". "Use <versión>" vuelve a la versión probada.
- Las conversaciones nuevas usan la versión actualizada; las abiertas conservan la suya hasta que se reinician.

---

## 11. Panel de GitHub (M2.7)

El panel derecho muestra el pull request (PR) de la rama del workspace y ofrece la siguiente acción.

### Diseño de la ventana

- El panel ocupa todo el alto de la ventana, a la derecha. Su encabezado está en la misma fila que la barra
  superior.
- Se muestra u oculta con el ícono de la esquina superior derecha o con ⌥⌘B (View ▸ Show/Hide Pull Request Panel).
- Su ancho se ajusta arrastrando la línea de la izquierda (de 280 a 480 puntos).
- La barra lateral izquierda se muestra u oculta con ⌃⌘S.

### El encabezado: estado y acción

El encabezado muestra el número del PR (un clic muestra la sección Checks; ⌘-clic o la flecha ↗ abren el PR en
GitHub), el estado y **una sola acción**. Rocky toma el primer estado de esta tabla que aplica:

| Estado (texto en pantalla) | Acción | Quién la hace |
| --- | --- | --- |
| Merged | Archive | Rocky |
| Queued to merge | Etiqueta "Queued" | — |
| Working… | Ninguna: el agente está en un turno | — |
| No changes yet | Ninguna | — |
| No pull request | Create PR | El agente |
| Uncommitted changes | Commit and push | El agente |
| Incompatible with remote / Remote branch was rebased | Resolve | El agente |
| Behind by N commits | Pull (`git pull --ff-only`) | Rocky |
| Ahead by N commits | Push | Rocky |
| Merge conflicts | Resolve | El agente |
| PR changes requested | Add all comments to chat | El agente |
| Draft PR open | Ready for review | Rocky |
| N / M checks failed | Fix errors (o View checks si el check no tiene enlace) | El agente (View checks abre el navegador) |
| N checks pending… | Ninguna | — |
| PR review required / Blocked from merging / Unable to merge | Ninguna | — |
| Checking mergeability… | Ninguna | — |
| Ready to merge | Merge | Rocky |

Qué hace cada acción:

- **Create PR:** le pide al agente que haga commit, `git push -u origin HEAD` y `gh pr create --base <base>`. La
  flecha junto al botón ofrece "Create draft PR" (lo mismo con `--draft`) y "Create PR manually ↗" (abre la página
  de GitHub para crearlo a mano).
- **Commit and push:** le pide al agente "Commit and push all changes."
- **Resolve (conflictos):** le pide al agente que traiga `origin/<base>` y resuelva los conflictos, con merge o con
  rebase según el `git config pull.rebase` del worktree.
- **Fix errors:** descarga las últimas 1000 líneas de los logs de los jobs fallidos de GitHub Actions y se los
  adjunta al agente. Los checks de otros sistemas van como una línea con su enlace.
- **Pull y Push:** los hace Rocky. Rocky nunca hace force-push ni crea commits de merge por su cuenta.

### Merge

- El botón usa uno de los métodos que el repositorio permite: "Squash", "Merge" o "Rebase". La flecha del botón
  abre el menú de métodos. Tu elección dura hasta que cierres Rocky.
- **Hacen falta dos clics.** El primero cambia el botón a "Confirm squash" (o el método elegido) durante 4 segundos.
  El segundo hace el merge y el botón dice "Merging…".
- Si GitHub rechaza el merge, el motivo aparece debajo de la fila de pestañas, con una × para cerrarlo.

### Archive

Después del merge, "Archive" corre el script Archive y quita el worktree; la rama se conserva.

- Si el worktree tiene cambios sin commit, pregunta "lima has 3 uncommitted changes. Archive anyway?". "Archive"
  guarda los cambios en un `git stash` del repositorio ("Rocky archived lima") y luego quita el worktree. No se
  pierde nada.
- Con "Archive a workspace when its pull request merges" encendido (Settings → GitHub), Rocky archiva solo cuando ve
  el merge. Si hay cambios sin commit, no archiva y avisa: "lima merged but has uncommitted changes; not archived".

### La sección Checks

Debajo del encabezado está la sección "Checks", en este orden:

1. **Título y descripción del PR.** Son **de solo lectura**: no se editan en Rocky. Puedes seleccionarlos para
   copiarlos. Si los cambias en GitHub, aparecen en el siguiente refresco. Sin PR, una nota explica que "Create PR"
   le pide al agente crearlo con `gh pr create`.
2. **Git status.** Filas como "2 uncommitted changes", "1 commit behind remote", "3 commits behind main", "No PR
   open", "PR is in draft", "Ready to merge" o "Up to date with main". Cada una trae su acción (Commit and push,
   Pull, Push, Create PR…). Tras el merge solo queda "Merged into main".
3. **Deployments.** Los despliegues del último commit, con su estado (Deployed, Failed, Deploying, Queued, Inactive)
   y un enlace "Open …".
4. **Checks.** Cada check con su estado y duración, y un enlace para abrirlo. "Re-run" vuelve a correr los jobs
   fallidos (solo los de GitHub Actions). "Fix errors" hace lo mismo que en el encabezado.
5. **Comments.** Los comentarios pendientes: hilos de revisión sin resolver, comentarios de la conversación y
   revisiones que piden cambios. Al pasar el mouse sobre uno: "Hide" (lo oculta para ese PR, también tras relanzar)
   y "Add to chat" (se lo envía al agente). "Add all to chat" los envía todos, numerados. Un comentario enviado queda
   marcado con un check.

Al pie del panel ves la cuenta y la hora del último refresco, por ejemplo "jhzl1 · Updated 12s ago".

### Cuándo se actualiza

- Solo se actualiza el workspace seleccionado.
- Cada 30 segundos mientras la ventana se vea, aunque otra app esté delante. Cada 15 segundos mientras corren checks
  o despliegues.
- Se detiene mientras la ventana no se ve (minimizada, oculta, tapada por completo o en otro Space). Al volver a
  verse, se actualiza enseguida.
- También se actualiza al seleccionar el workspace, al volver a Rocky, después de una acción de Rocky y al terminar
  un turno del agente (esto último, aunque el workspace no esté seleccionado).
- **No hay botón para actualizar a mano.** Solo aparece "Retry" cuando hay un error.

### Todo lo del agente pasa por la conversación

Create PR, Commit and push, Resolve, Fix errors y los comentarios se envían a la conversación seleccionada del
workspace, como si tú hubieras escrito el mensaje. Así ves lo que hace el agente. Mientras corre un turno, esos
botones están desactivados con el tooltip "The agent is working" y el encabezado dice "Working…". Estos botones
nunca usan la cola de mensajes. Si el agente está detenido, el tooltip dice "Restart the agent first".

---

## 12. Cómo reconoce Rocky el repositorio y la cuenta de GitHub

Rocky responde tres preguntas, en orden: ¿qué repositorio de GitHub es?, ¿con qué cuenta lo leo?, ¿qué PR muestro?

### Paso 1: el repositorio

Rocky corre `git remote get-url origin` en el clon principal y saca de la URL el dueño y el nombre:

| URL de `origin` | Dueño / nombre |
| --- | --- |
| `git@github.com:jhzl1/rocky.git` | `jhzl1` / `rocky` |
| `https://github.com/RentekFintech/doculift.git` | `RentekFintech` / `doculift` |
| `git@github-celes:celes-app/celes-platform.git` (alias SSH, ejemplo) | `celes-app` / `celes-platform` |

Lo hace una vez por repositorio en cada sesión.

### Paso 2: los alias SSH

Si la URL usa SSH con un host distinto de `github.com`, ese host es un alias de `~/.ssh/config`. Tu configuración
tiene, por ejemplo:

```
Host github-celes
  HostName github.com
  IdentityFile ~/.ssh/id_rsa_celes
```

y también `github.com-personal` y `github.com`, los dos con `~/.ssh/id_rsa_personal`.

Rocky corre `ssh -G <alias>`, que imprime la configuración que usaría ssh **sin conectarse**, y lee su línea
`hostname`. Puedes verlo tú mismo:

```
ssh -G github-celes | rg '^hostname'
# hostname github.com
```

- Solo `github.com` cuenta como GitHub. Con cualquier otro host, el panel dice "PR info unavailable".
- **El alias no elige la cuenta de GitHub.** La llave SSH (`IdentityFile`) solo importa para las operaciones de git
  contra el remoto (`git fetch`, `git pull`, `git push`).

### Paso 3: la cuenta

Rocky usa las cuentas de `gh`. Tus cuentas son `jhzl1` (la activa) y `ocampos-biai`.

1. **Si elegiste una cuenta** en los ajustes del repositorio (sección GitHub), esa gana siempre.
2. **Con "Automatic"**, Rocky decide en tres pasos:
   1. Si una cuenta se llama igual que el dueño (sin distinguir mayúsculas), usa esa. Ejemplo: `jhzl1/rocky` →
      `jhzl1`.
   2. Si el dueño es una organización, prueba cada cuenta, **primero la activa**, con **una sola** petición:
      `GET https://api.github.com/repos/<dueño>/<nombre>`, con el token de esa cuenta. Solo mira el código de
      respuesta:
      - 200: esa cuenta puede leer el repositorio.
      - 404 (un repositorio privado que la cuenta no ve), 401 o 403: no puede.
      - Se detiene en la primera que responde 200.
   3. Si ninguna responde 200, usa la cuenta activa.

Detalles de la prueba:

- Corre una vez por repositorio en cada sesión, nunca con un temporizador.
- Una cuenta que no respondió (sin internet, o con el límite de peticiones de GitHub agotado) se vuelve a probar la
  próxima vez que Rocky necesite la cuenta.
- Con una sola cuenta en `gh` no hay prueba: no cambiaría nada.

El menú de cuentas muestra lo que decidió "Automatic", por ejemplo "Automatic (jhzl1)".

### Tus repositorios

Verificado el 2026-09-24:

| Repositorio | `jhzl1` | `ocampos-biai` | Cuenta elegida |
| --- | --- | --- | --- |
| `RentekFintech/doculift` | 200 | 404 | `jhzl1` |
| `RentekFintech/veritas` | 200 | 404 | `jhzl1` |
| `celes-app/celes-platform` | 404 | 200 | `ocampos-biai` |

En `celes-platform` la cuenta activa (`jhzl1`) recibe 404, así que Rocky sigue con `ocampos-biai`, que recibe 200.

### Comprobarlo desde la terminal

Esto hace lo mismo que la prueba de Rocky, con cada cuenta:

```
GH_TOKEN=$(gh auth token --user jhzl1) gh api repos/celes-app/celes-platform
GH_TOKEN=$(gh auth token --user ocampos-biai) gh api repos/celes-app/celes-platform
```

Si imprime los datos del repositorio, esa cuenta puede leerlo (200). Si termina con `Not Found (HTTP 404)`, no puede.

### El token

- Rocky obtiene el token con `gh auth token --user <cuenta>`, una vez por sesión, la primera vez que lo necesita.
- Lo guarda solo en memoria. Nunca lo escribe en la base de datos, en un log, en una URL ni en un mensaje de error.

### Dónde se usa el token

1. En las llamadas de Rocky a GitHub (GraphQL y REST, solo a `api.github.com`).
2. Como `GH_TOKEN` en los agentes, terminales y scripts del workspace. Un repositorio sin remoto de GitHub no recibe
   ninguno.

Si una variable aparece en varias capas, gana la última:

| Orden | Capa |
| --- | --- |
| 1 | Tu shell de inicio de sesión |
| 2 | Las variables de Rocky (`PORT`, `ROCKY_*`) |
| 3 | Las variables del repositorio |
| 4 | El `GH_TOKEN` de la cuenta del repositorio |

Por eso, cuando el agente corre `gh pr create`, lo hace con la cuenta correcta. Los procesos que ya corren conservan
el token con el que arrancaron. Si cambias la cuenta, los ajustes lo recuerdan: "Restart the conversation's agent to
use the new account."

### `git push` por SSH

`git push` por SSH usa la llave SSH, no el token.

- Rocky respeta el `core.sshCommand` del repositorio. En tu caso viene de:
  - `~/.gitconfig`: `[includeIf "gitdir:~/Documents/dev/celes/"]`, con `path = ~/.gitconfig-celes`.
  - `~/.gitconfig-celes`: `sshCommand = ssh -o IdentitiesOnly=yes -o IdentityFile=/Users/jhzl/.ssh/id_rsa_celes`.
- Los worktrees viven al lado del repositorio (`celes-platform-worktrees/`), dentro de `~/Documents/dev/celes/`, así
  que la regla `includeIf` también aplica en ellos.
- En sus propias operaciones contra el remoto (el `git fetch` al crear un workspace, Pull y Push del panel), Rocky
  solo añade `-o BatchMode=yes` al comando que git usaría. Así ssh falla en lugar de quedarse esperando una
  contraseña. Si tu shell define `GIT_SSH_COMMAND`, se usa ese.
- El `git push` del agente no recibe nada de Rocky: git usa tu `core.sshCommand` como siempre.

### Qué PR muestra

1. Rocky toma la rama que está activa en el worktree, según `git status`. Si el agente cambia de rama, el panel la
   sigue. Si no la conoce todavía, usa la rama del workspace (`rocky/<ciudad>`).
2. Pide a GitHub, por GraphQL, `pullRequests(headRefName: <rama>, states: [OPEN, MERGED], first: 1)`: el PR más
   reciente de esa rama, abierto o fusionado.
3. Un PR cerrado sin merge no cuenta: el panel vuelve a ofrecer "Create PR".

### Lo que no cubre

- Cuentas sin sesión en `gh`. Corre `gh auth login --hostname github.com`. Rocky ve la cuenta nueva al abrir los
  ajustes del repositorio (que vuelven a leer las cuentas de `gh`) o al relanzar; luego pulsa "Retry" en el panel.
- GitHub Enterprise, o cualquier host distinto de `github.com`.
- Remotos que no se llamen `origin`.
- PRs que vienen de un fork.
- PRs de una rama que ningún worktree de Rocky tiene activa.

---

## 13. Atajos de teclado

| Atajo | Qué hace | Dónde |
| --- | --- | --- |
| ⌘, | Abre Settings | Menú Rocky |
| ⌘N | Nuevo workspace | Menú File |
| ⌘K | Busca workspaces | Menú View |
| ⌘1 … ⌘9 | Selecciona el workspace visible número N | Menú View |
| Mantener ⌘ | Muestra el atajo de cada fila | Barra lateral |
| ↑ / ↓ | Mueven la selección | Barra lateral, con la lista enfocada |
| ⌃⌘S | Muestra u oculta la barra lateral | Menú View |
| ⌥⌘B | Muestra u oculta el panel de GitHub | Menú View |
| ⌘+ (o ⌘=) | Acerca (zoom) | Menú View |
| ⌘- | Aleja | Menú View |
| ⌘0 | Tamaño real (100 %) | Menú View |
| ⌘J | Pliega o despliega el panel de terminal | Panel de terminal |
| Return | Envía (o pone en cola) | Cuadro de mensaje |
| ⇧Return, ⌥Return | Nueva línea | Cuadro de mensaje |
| ⇧Tab | Modo plan | Cuadro de mensaje |
| ⌘U | Adjunta archivos | Cuadro de mensaje |
| ↑ / ↓ | Mensajes anteriores (cuadro vacío) | Cuadro de mensaje |
| Esc | Detiene el turno del agente | Conversación |
| ↑ / ↓, Return, Tab, Esc | Elegir, ejecutar, completar, cerrar | Lista de comandos "/" (M2.6) |
| Return | Elige el primer modelo que coincide | Buscador del menú de modelos |
| ⌘S | Guarda | Ajustes del repositorio |
| Return | Añade la ruta escrita | Ajustes del repositorio, "Path or glob" |
| Esc | Cierra sin guardar | Settings y ajustes del repositorio |
| ⌘-clic en el número del PR | Abre el PR en GitHub | Panel de GitHub |

---

## 14. Energía

Rocky está hecho para gastar poca batería, incluso con muchos workspaces abiertos.

- **Nada consulta nada en reposo.** Rocky no revisa el disco con temporizadores. Git corre solo después de un evento
  (seleccionar un workspace, volver a la ventana, una acción tuya, el fin de un turno). La vigilancia de archivos
  con FSEvents llega con M3.
- **Las animaciones se pausan solo cuando la ventana no se ve** (minimizada, oculta, tapada o en otro Space). Con
  Rocky visible detrás de otra app siguen, para que un agente que trabaja no parezca congelado. El círculo de carga
  usa Core Animation; el texto brillante de "Working" es el único costo visible (hasta 30 cuadros por segundo).
- **GitHub no lanza procesos.** Cada refresco es una petición `URLSession` a GitHub, y dos cuando el panel muestra
  los comentarios de un PR abierto. `gh` solo corre para leer las cuentas y los tokens, una vez por sesión.
- **Los agentes arrancan cuando hacen falta:** el de la conversación en pantalla, y los demás al abrirlos.
- **Las actualizaciones de agentes** se consultan una vez al día, con una petición HTTPS a npm.

Para medir el consumo:

```
scripts/energy-report.sh 30
```

Compara Rocky con Conductor en los últimos 30 minutos, con datos del registro de energía de macOS: energía, segundos
de CPU y procesos iniciados (en total y por minuto). El registro se escribe con retraso, así que los últimos minutos
pueden faltar. El objetivo en reposo es menos de 5 procesos por minuto.

---

## 15. Problemas comunes y qué hacer

### "PR info unavailable"

Rocky no reconoce el repositorio en GitHub. Hay dos causas: `origin` no apunta a `github.com`, o la cuenta elegida no
puede ver el repositorio (GitHub responde 404). El panel lo explica así: "origin is not on github.com, or this account
cannot see the repository."

1. Revisa el remoto en el clon principal: `git remote get-url origin`.
2. Si usa un alias SSH, revisa que apunte a GitHub: `ssh -G <alias> | rg '^hostname'` debe decir `github.com`.
3. Revisa la cuenta en los ajustes del repositorio. Prueba cada cuenta con los comandos de la sección 12 y elige la
   que recibe 200.
4. Pulsa "Retry".

### "GitHub access required"

Rocky no tiene token para la cuenta del repositorio: `gh` no está instalado, no tiene cuentas, o GitHub rechazó el
token.

1. Corre `gh auth login --hostname github.com` en una terminal. El panel muestra el comando con un botón "Copy".
2. Abre los ajustes del repositorio, o relanza Rocky, para que lea la cuenta nueva.
3. Pulsa "Retry".

Si los ajustes del repositorio dicen "The GitHub CLI (gh) is not on your login shell's PATH", instala `gh` y relanza
Rocky.

### "git fetch failed; lima was created from the last fetched origin/main."

El `git fetch` falló al crear el workspace (sin internet, o la llave SSH no tiene acceso). El workspace se creó de
todos modos, pero desde la última copia descargada de la rama base, que puede estar desactualizada.

1. En el clon principal, prueba `git fetch origin`.
2. Si falla por la llave, revisa el `core.sshCommand` del repositorio y tu `includeIf` (sección 12).
3. Crea un workspace nuevo, o pídele al agente que traiga los cambios de `origin/<base>`.

### Error de autenticación en una conversación

Si una conversación de Claude falla porque la instancia de Claude no tiene sesión iniciada:

1. Abre los ajustes del repositorio → sección Claude.
2. Elige otra instancia (una que tenga sesión) y pulsa Save.
3. La conversación en pantalla se vuelve a abrir con la instancia nueva. Como esa instancia no conoce la sesión
   anterior, verás "Could not resume the previous conversation …" y el agente empieza una sesión nueva.

### "Could not resume the previous conversation (…); started a new one."

El agente ya no tiene la sesión de esa conversación. Pasa, por ejemplo, después de cambiar la instancia de Claude.
Rocky sigue mostrando los mensajes anteriores, porque los guarda él, pero el agente empieza sin recordarlos. Si
necesitas ese contexto, resúmelo en tu siguiente mensaje.

### "Archive script failed"

El script Archive terminó con error y el workspace no se quitó. Revisa la pestaña Archive. "Remove Anyway" lo quita
sin volver a correr el script.

### El Llavero pide los secretos después de cada compilación

Falta el certificado "Rocky Local" (sección 2).

### Dónde están los logs

- `~/Library/Logs/Rocky`: lo que cada agente escribe en stderr. Settings → Data → Logs lo abre en Finder.
- `~/Library/Application Support/Rocky/ci-logs`: los logs de CI que "Fix errors" adjuntó.
- La salida de los scripts está en sus pestañas del panel inferior mientras Rocky esté abierto.

---

## 16. Próximamente

- **M2.8, conversaciones:** "+" abre una conversación enseguida con el último agente usado en el repositorio, y el
  agente se elige desde el menú de modelos.
- **M3, revisar y editar:** una pestaña Changes en el panel derecho, el diff de cada archivo, comentarios en líneas
  para enviar al agente, un editor dentro de Rocky y commits desde Rocky.

---

Esta guía se actualiza con cada nueva función de Rocky. Si algo de la app no coincide con lo que dice aquí, la guía
está desactualizada: avisa para corregirla.
