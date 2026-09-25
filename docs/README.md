# Guía de uso de Rocky

Última actualización: 2026-09-25

Rocky es una app de macOS para trabajar con agentes de código (Claude Code y OpenCode) en paralelo. Cada tarea vive
en su propio workspace, con su propia copia del repositorio, así que varios agentes pueden trabajar a la vez sin
pisarse. La idea viene de Conductor.

**Estado de esta guía.** Describe lo construido de M1 a M3:

- M3 (revisar y editar: las pestañas All files y Changes, los diffs, los comentarios en líneas, el editor y los
  commits desde Rocky) está en `development` desde el 2026-09-24. Quick Open (⌘P), los comentarios que salen al
  escribirlos (sección 15), los íconos de cada tipo de archivo (sección 17), la app por defecto del botón Open y de
  la ruta de las pestañas (secciones 3 y 14), el "+" que crea la conversación de inmediato (sección 6), ↑ sobre un
  comentario en líneas (sección 15), las líneas agregadas y quitadas en cada edición del agente (sección 6) y los
  arreglos del editor que vinieron después están en la rama `fix/m3-editor-and-quick-open`.
- M2.6 (los comandos con "/" y la tecla Esc dentro de un terminal) y M2.7 (el panel de GitHub) ya están en
  `development`.

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
| `~/Library/Application Support/Rocky/rocky.sqlite` | La base de datos: repositorios, workspaces, conversaciones (con sus comentarios en líneas), las carpetas abiertas de All files y los archivos recientes de Quick Open. |
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

Arriba de la conversación ves `repositorio / rama`. Un clic en la rama la copia.

A la derecha está el botón Open, que tiene dos partes:

- **La parte izquierda** muestra el ícono de la app por defecto y abre el worktree en ella. Hace lo mismo que ⌘O
  (File ▸ Open in …, con el nombre de la app). Su tooltip dice, por ejemplo, "Open in Zed (⌘O)".
- **La flecha** abre el menú. Cada opción es el ícono de la app y su nombre:
  - Finder.
  - Antigravity, Cursor, VS Code y Zed, solo los que tengas instalados, en orden alfabético.
  - New Terminal (abre un terminal en el panel inferior).
  - Copy Path (copia la ruta del worktree).

  La app por defecto muestra "⌘O" a la derecha.

**La app por defecto** es la última que elegiste en ese menú. Elegir Finder o un editor abre el worktree ahí y la
convierte en la app por defecto. New Terminal y Copy Path no la cambian. Es una sola para todo Rocky, y se recuerda al
relanzar.

- Si nunca elegiste una, es el primer editor instalado de la lista (Antigravity, Cursor, VS Code, Zed). Sin editores,
  es Finder.
- Si desinstalas la app por defecto, Rocky usa esa misma regla mientras falte, y la recupera si la vuelves a instalar.
- Rocky busca las apps cada vez que las usa (al dibujar el botón, al abrir el menú, en cada clic y con ⌘O), sin
  revisar nada en reposo.

La misma app abre el archivo de una pestaña cuando haces clic en su ruta (sección 14).

### Al abrir Rocky de nuevo

Rocky abre el último workspace que tenías seleccionado, y en cada workspace, la última conversación que mirabas.

### Quitar (archivar) un workspace

1. Pulsa "Remove workspace" en la fila, o "Remove Workspace…" en su menú.
2. Confirma con "Remove Worktree".

Rocky detiene sus agentes, terminales y scripts, corre el script Archive y borra la carpeta del worktree. **La rama
se conserva**, así que no pierdes commits. Git se niega si hay cambios sin commit, y la carpeta se queda.

Si el script Archive falla, no se borra nada. Aparece "Archive script failed" con "Remove Anyway" (quita el
workspace sin volver a correr el script) y "Cancel". La pestaña Archive muestra la salida del script.

El panel derecho tiene otras dos formas de archivar después de un merge (sección 11).

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

Las conversaciones del workspace aparecen como pestañas sobre el chat. Cerrar una pestaña detiene su agente, y la
conversación queda guardada.

- **Un clic en el "+"** al final de las pestañas crea una conversación de inmediato, sin menú. Su pestaña aparece al
  final, queda seleccionada y el cuadro de mensaje toma el teclado.
- **El agente de la nueva conversación** es el de la conversación donde enviaste tu último mensaje en ese
  repositorio, en cualquiera de sus workspaces, aunque ya hayas cerrado esa pestaña. Si aún no enviaste ninguno, es
  Claude Code. La primera conversación que un workspace abre solo sigue la misma regla.
- **Clic derecho en el "+"** muestra "New Claude Code conversation" y "New OpenCode conversation", para elegir el
  agente. Por ahora es la única forma de abrir una conversación de OpenCode sin haber usado OpenCode antes en el
  repositorio. Elegir uno ahí no cambia el agente por defecto: lo cambia el primer mensaje que envíes.

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
mueven el cursor como siempre. Un comentario en líneas vuelve con su etiqueta al inicio y el comentario después
(sección 15).

### Mensajes en cola

Si el agente está trabajando, Return no interrumpe: el mensaje entra en una cola y sale cuando termina el turno.

- Los mensajes en cola aparecen al final de la conversación, más tenues y con borde punteado, con la leyenda
  "Queued" o "3 queued".
- Al pasar el mouse sobre uno aparecen:
  - "Send now": detiene el turno en curso y envía ese mensaje primero.
  - "Edit": lo devuelve al cuadro para editarlo. Solo funciona con el cuadro vacío.
  - "Delete": lo borra.
- Un comentario en líneas en cola muestra su etiqueta y ofrece "Send now", "Edit" y "Remove" (sección 15).
- Si detienes el turno, o el agente falla, la cola queda en espera. La leyenda dice "On hold until your next message".
  Sale cuando envías otro mensaje o pulsas "Send now".
- La cola vive en memoria: si cierras Rocky, se pierde.

### Detener un turno

Pulsa Esc o el botón de detener (cuadrado). El turno termina con la marca "INTERRUPTED BY USER". También aparece
después de "Send now", porque ese botón detiene el turno en curso.

Esc va primero a lo que esté abierto encima: un menú, los ajustes, Quick Open, un diálogo o una hoja (como la del
commit). Tampoco
detiene el turno mientras escribes en el editor o en su barra de búsqueda, en el filtro de All files o en un
comentario: ahí Esc es de ese campo. Solo cuando no pasa nada de eso detiene el turno.

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
resume the previous conversation (…); started a new one." (sección 21). Una conversación sin mensajes empieza una
sesión nueva sin error.

Si el agente se detiene, el cuadro de mensaje muestra el motivo y un botón "Restart".

### Las líneas de cada edición

Cuando el agente edita o crea archivos (Edit, MultiEdit y Write de Claude Code; edit, write y patch de OpenCode), la
fila de esa acción muestra `+A −D` después de las etiquetas de sus archivos: las líneas que agregó (verde) y las que
quitó (rojo), con los miles como "2.3k", igual que en Changes (sección 13). Por ejemplo, "Edit README.md +1 −1".

- Los números aparecen cuando la edición termina. Mientras corre, si falla o si la rechazas, no hay números, porque
  el archivo no cambió.
- Se muestran los dos números, también "+10 −0". Si los dos son 0, la fila no muestra nada.
- Una acción que toca varios archivos muestra la suma de todos.
- Las líneas de contexto que el agente envía alrededor del cambio no cuentan.
- Un grupo de acciones ("3 tool calls") muestra después de su título la suma de sus filas, también cuando está
  plegado. Es lo que dicen las filas, no el cambio neto de los archivos: una línea editada dos veces cuenta dos veces.
- Si Rocky tiene que comparar más de 5000 líneas entre el texto anterior y el nuevo (por ejemplo, al reescribir un
  archivo grande entero), esa acción no muestra números.
- Los números se guardan con la conversación, así que siguen ahí al relanzar Rocky. Las ediciones guardadas antes de
  esta función no tienen números.

### Pestañas de archivos

Un clic en la etiqueta de un archivo, en tus mensajes o en las acciones del agente (Read, Edit…), abre el archivo en
una pestaña junto a las conversaciones:

- Un archivo del worktree que está en Changes abre su pestaña de diff, en su primer bloque de cambios (sección 14).
  Así ves qué cambió el agente.
- Otro archivo del worktree abre su pestaña en el editor, con la marca "Unchanged" (sección 16).
- Un archivo fuera del worktree abre una pestaña de archivo: imágenes, código y texto en el editor, Markdown con
  Preview | Edit, PDF en la vista rápida de macOS, y lo demás como "Binary file" (sección 17). Su encabezado muestra
  la ruta completa, que se abre con un clic en la app por defecto como en una pestaña de diff (sección 14).

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

## 11. El panel derecho y GitHub

El panel derecho muestra el pull request (PR) de la rama del workspace y ofrece la siguiente acción (M2.7). Desde M3
también tiene los archivos del worktree y lo que cambió.

### Las pestañas del panel

Debajo del encabezado hay tres pestañas en forma de pastilla: **All files · Changes N · Checks**.

| Pestaña | Qué muestra |
| --- | --- |
| All files | El árbol de archivos del worktree, con un filtro (sección 17). |
| Changes N | Los archivos que cambiaron frente a la base; N es cuántos, y no aparece cuando es 0 (sección 13). |
| Checks | El PR: git status, despliegues, checks y comentarios (más abajo). |

- Cada workspace recuerda su pestaña mientras Rocky está abierto. Un workspace que todavía no eligió ninguna muestra
  Changes.
- ⌘⇧C (View ▸ Show Changes) abre el panel en Changes. Pulsado mientras Changes se ve, oculta el panel (View ▸ Hide
  Changes).
- ⌘P (File ▸ Go to File…) abre Quick Open, que busca en los archivos del worktree sin cambiar el panel
  (sección 17).

### Diseño de la ventana

- El panel ocupa todo el alto de la ventana, a la derecha. Su encabezado está en la misma fila que la barra
  superior.
- Se muestra u oculta con el ícono de la esquina superior derecha o con ⌥⌘B (View ▸ Show/Hide Pull Request Panel). El
  menú conserva ese nombre, aunque el panel ahora tenga también archivos y cambios.
- Su ancho se ajusta arrastrando la línea de la izquierda (de 280 a 480 puntos).
- La barra lateral izquierda se muestra u oculta con ⌃⌘S.

### El encabezado: estado y acción

El encabezado muestra el número del PR (un clic muestra la pestaña Checks; ⌘-clic o la flecha ↗ abren el PR en
GitHub), el estado y **una sola acción**. Rocky toma el primer estado de esta tabla que aplica:

| Estado (texto en pantalla) | Acción | Quién la hace |
| --- | --- | --- |
| Merged | Archive | Rocky |
| Queued to merge | Etiqueta "Queued" | — |
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

### La pestaña Checks

La pestaña "Checks" muestra, en este orden:

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
   marcado con un check. Rocky solo lee estos comentarios mientras la pestaña Checks se ve.

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
botones están desactivados con el tooltip "The agent is working"; el encabezado sigue mostrando el estado del pull
request. Estos botones nunca usan la cola de mensajes. Si el agente está detenido, el tooltip dice "Restart the agent first".

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

## 13. Changes: lo que cambió en el workspace

La pestaña Changes del panel derecho lista cada archivo que cambió frente a la **base** del workspace: el commit donde
su rama se separa de la rama base (`git merge-base <rama base> HEAD`). Los commits nuevos de la rama base no aparecen
como cambios.

Entra todo lo que cambió en el workspace:

- los commits de su rama;
- los cambios en el índice (staged) y los que todavía no agregaste;
- los archivos nuevos que git aún no sigue (untracked), que aparecen como agregados.

Un workspace sin rama base guardada (los creados en M1) usa la rama de `origin/HEAD` o, sin `origin`, la rama actual
del clon principal.

### Los números en la barra lateral y en la pestaña

- Cada fila de la barra lateral muestra `+A −D`: líneas agregadas (verde) y borradas (rojo), con los miles como
  "2.3k". Cuentan también las líneas de los archivos nuevos. Se ocultan al pasar el mouse y mientras mantienes ⌘.
- La pestaña dice "Changes N", con N archivos cambiados. Con 0 dice solo "Changes".
- Los dos se actualizan solos cuando algo cambia en el worktree: el agente, un terminal o git. Rocky se entera por
  FSEvents, sin revisar el disco con temporizadores (sección 20).
- Mientras hay un rebase o un merge a medias, o git tiene el índice bloqueado (`index.lock`), Rocky no lee los cambios.
  Lo intenta de nuevo con el siguiente cambio en el disco.

### La lista

Arriba hay una fila con la cantidad de archivos ("5 files"), el total `+A −D` y "⋯" (Refresh, Discard All Uncommitted
Changes…). Debajo, dos grupos:

| Grupo | Qué tiene |
| --- | --- |
| UNCOMMITTED · N | Archivos con cambios sin commit, y el botón "Commit…" (sección 18). Un archivo con cambios con commit y sin commit va aquí. |
| COMMITTED · N | Archivos que cambiaron en commits de esta rama y no tienen nada pendiente. |

Cada fila muestra:

- la letra de estado: A (agregado, verde), M (modificado, ámbar), D (borrado, rojo) o R (renombrado, gris);
- el ícono del tipo de archivo (sección 17, "Íconos de los archivos");
- el nombre y su carpeta;
- `+a −d`.

Al pasar el mouse, las cifras se cambian por Edit (lápiz) y, en archivos sin commit, Discard (flecha hacia atrás). El
tooltip muestra la ruta, o "ruta/vieja → ruta/nueva" en un renombre.

- **Un clic** abre la pestaña de diff del archivo (sección 14), o la selecciona tal como la dejaste. **Edit** la abre
  en modo Edit (sección 16).
- La fila del archivo que tienes en pantalla se ve seleccionada.
- **⌥⌘↓ / ⌥⌘↑** (View ▸ Next Changed File / Previous Changed File) abren el archivo siguiente o el anterior de la
  lista. Están apagados mientras Rocky no tiene los cambios leídos: con el panel en Checks o cerrado, y sin una
  pestaña de diff en pantalla.
- Sin cambios, la pestaña dice "No changes yet" y "Changes the agent makes in this workspace show up here."
- Si git falla, su error aparece en rojo debajo de la primera fila, con × para cerrarlo.

### Descartar cambios

Solo se pueden descartar cambios sin commit. Rocky nunca descarta un commit.

1. Pulsa Discard en la fila, o "Discard Changes…" en el menú "⋯" de la pestaña de diff. Para todos los archivos a la
   vez: "⋯" ▸ Discard All Uncommitted Changes….
2. Confirma. Para un archivo: "Discard changes to openapi.ts?", "This cannot be undone." y "Discard Changes". Para
   varios: "Discard the uncommitted changes of 3 files?" y "Discard All".

Qué hace Rocky con cada archivo:

| Archivo | Qué pasa |
| --- | --- |
| Seguido por git | Vuelve a como está en el último commit (`git restore --staged --worktree`). |
| Nuevo, sin agregar a git (untracked) | Va a la Papelera. No se borra. |
| Nuevo, solo agregado al índice (staged) | Sale del índice y va a la Papelera. |
| Renombrado en el índice | El nombre nuevo va a la Papelera y el original vuelve. |

La pestaña de diff del archivo se cierra. Rocky no descarta un archivo que cambió de estado desde que leyó la lista,
por ejemplo uno nuevo que el agente acaba de agregar a git.

---

## 14. Pestañas de diff

Cada archivo cambiado se abre en su propia pestaña, en la fila de las conversaciones, después de ellas y de las
pestañas de archivos. Hay una sola pestaña por archivo.

- La pestaña muestra la letra de estado en lugar del ícono. El tooltip es la ruta.
- Con cambios sin guardar, un punto ocupa el lugar de la × hasta que pasas el mouse (sección 16).

### El encabezado

De izquierda a derecha:

1. La ruta: el ícono del archivo, la carpeta y el nombre, en un recuadro. En un renombre, "ruta/vieja → ruta/nueva".
   Un clic abre el archivo en la app por defecto (sección 3); si es Finder, lo muestra en Finder. El tooltip dice
   "Open in Zed" (con el nombre de la app) o "Reveal in Finder". Abre el archivo tal como está en el disco, sin tus
   cambios sin guardar. Un archivo borrado no está en el disco, así que su ruta es texto normal, sin recuadro.
2. `+a −d`, y "New file" si el archivo es nuevo.
3. "Edited" y Save mientras hay cambios sin guardar, o "Reloaded" (sección 16).
4. El selector **Diff | Edit** (sección 16).
5. "⋯": Reveal in All Files, Open in Finder, Copy Path y, en archivos sin commit, Discard Changes….

### El diff unificado

- Es de solo lectura. Para escribir, cambia a Edit.
- Tiene una sola columna de números, como Conductor: el número nuevo, o el viejo en una línea borrada. Es verde en
  las líneas agregadas, rojo en las borradas y gris en las demás. Después vienen la marca `+` o `−` y el código con
  colores de sintaxis.
- Las líneas agregadas tienen fondo verde; las borradas, fondo rojo.
- Cada bloque de cambios (hunk) trae tres líneas sin cambios alrededor. Como en Conductor, no se muestra el
  encabezado `@@` de git.
- Las líneas sin cambios entre bloques se pliegan en una fila como "⋯ 18 unchanged lines". Un clic la despliega.
- El diff empieza arriba de la pestaña, aunque sea corto.

Las líneas largas no se cortan: el diff se desplaza hacia los lados y la columna de números se queda fija. El texto de
cada línea se puede seleccionar para copiarlo.

### Colores de sintaxis

Rocky colorea el código con Prism 1.30.0, que viene dentro de la app, tanto en el diff como en el editor. Elige el
lenguaje por la extensión del archivo: TypeScript, JavaScript, TSX, JSX, JSON, Swift, Python, Go, Rust, CSS, HTML y
XML, YAML, TOML, shell (`.sh`, `.zsh`, `.zshrc`…), Markdown y SQL. Cualquier otro archivo se ve como texto sin colores.

- El texto aparece sin colores un momento, hasta que Prism termina.
- Quedan sin colores los archivos de solo lectura por su tamaño (sección 17) y los textos de más de un millón de
  caracteres.

### Casos especiales

| Archivo | La pestaña muestra |
| --- | --- |
| Nuevo | Todas sus líneas como agregadas, y "New file" en el encabezado. Si está vacío, "Empty file". |
| Borrado | Todas sus líneas como borradas. Edit está apagado. |
| Renombrado | "ruta/vieja → ruta/nueva" y solo las líneas que cambiaron. Sin cambios de contenido: "Renamed without changes". |
| Binario | "Binary file · 24 KB → 31 KB", sin líneas. Edit está apagado. |
| Grande: más de 1500 líneas cambiadas o de 1 MB | "Large diff · N lines" y el botón Show, que muestra el diff. |
| Nuevo, sin agregar a git, de más de 20 MB | "This file is too large to show in Rocky." |
| Solo cambió el modo | "File mode changed 644 → 755". |

---

## 15. Comentarios en líneas

En el modo Diff de una pestaña puedes comentar una línea o un rango y enviar el comentario a una conversación del
workspace en el momento, como en Conductor. Rocky no guarda los comentarios: la conversación los guarda, como a
cualquier otro mensaje.

### Escribir un comentario

1. Pasa el mouse sobre una línea: aparece un "+" sobre su número.
2. Elige las líneas:
   - un clic en el "+" o en el número comenta esa línea;
   - arrastrar desde el "+" o desde un número elige un rango;
   - ⇧-clic en otro número elige un rango desde la línea que marcaste antes.
3. Se abre un cuadro debajo de la última línea del rango. Las líneas elegidas quedan marcadas mientras el cuadro está
   abierto.
4. Escribe el comentario y pulsa Send o ⌘Return. Return agrega una línea nueva.

El diff tiene una sola columna de números (sección 14). En una línea borrada ese número es el de la línea vieja, así
que el comentario queda del lado borrado. Un rango queda de un solo lado: líneas nuevas (agregadas y sin cambios) o
líneas borradas.

### El cuadro

- **"Sending to"** muestra la conversación que recibirá el comentario, con el ícono de su agente. Un clic abre la
  lista de conversaciones abiertas del workspace, con un check en la elegida. Por defecto es la última conversación
  que mostraste en el workspace.
- **La etiqueta de las líneas** va al inicio del texto: el ícono del archivo, su nombre y el rango. Por ejemplo,
  "openapi.ts +18–25" para líneas nuevas, "−12–13" para líneas borradas y "+18" para una sola línea. No se puede
  borrar: Cancel descarta el comentario entero.
- **Send** está apagado mientras el texto está vacío. Si la conversación elegida está en un turno, el botón dice
  "Queue" y su tooltip "Claude Code is working; this goes out when its turn ends".
- **Cancel** cierra el cuadro. Esc también, pero si el cuadro tiene texto pregunta antes "Discard this comment?"
  (Discard o Keep Editing). Mientras escribes, Esc no detiene el turno del agente.
- **El cuadro se conserva** en memoria mientras la pestaña del diff está abierta. Si cambias de pestaña, o pasas a
  Edit y vuelves, lo encuentras como lo dejaste. Si eliges otras líneas del mismo archivo, el cuadro se mueve y el
  texto se mantiene. Cerrar la pestaña lo descarta.
- Abrir un cuadro en una pestaña de vista previa la conserva como pestaña normal (sección 17), para que un clic en el
  árbol no se lleve el comentario.

### Al enviarlo

1. El comentario sale en ese momento hacia la conversación elegida, aunque no esté en pantalla. Si su agente no ha
   arrancado, o está detenido, Rocky lo arranca primero. El diff se queda donde estaba.
2. El cuadro se cierra y aparece el aviso "Sent to “Review the schemas”". **Show** abre esa conversación. Un aviso con
   Show dura 4 segundos.
3. Si la conversación está en un turno, el comentario entra en su cola (sección 6) y sale cuando el turno termina. El
   aviso dice "Queued in “Review the schemas”", también con Show.
4. Si la conversación no puede recibirlo (se cerró, o su agente no arranca), el comentario vuelve a su cuadro con su
   texto, y el aviso dice "Couldn’t send to “…”".

El agente recibe el código de las líneas junto con el comentario, en un solo bloque de texto, con la ruta relativa al
worktree:

````
Comment on src/openapi.ts, lines 18–25:
```ts
function operation(route: Route) {
  …
```
Use the route's name as operationId only when it is unique.
````

- En líneas borradas dice "Comment on src/openapi.ts, removed lines 12–13 (from the base):" y trae el código de la
  base.
- El código se toma al pulsar Send. Un comentario en cola guarda ese código, aunque el agente cambie el archivo
  durante su turno.

### En la conversación

- Tu mensaje muestra la etiqueta de las líneas arriba y el comentario debajo. No muestra el código que recibió el
  agente.
- Un clic en la etiqueta abre la pestaña de diff del archivo en esas líneas, y despliega las líneas sin cambios que
  las esconden. Si el archivo ya no tiene cambios, abre su pestaña en el editor (sección 16). El tooltip muestra la
  ruta y el rango.
- En la cola, un comentario se ve con su etiqueta, como los demás mensajes en cola. Al pasar el mouse ofrece "Send
  now", "Edit" y "Remove". "Edit" solo funciona con el cuadro de mensaje vacío.

### Volver a enviar un comentario

Con el cuadro de mensaje vacío, ↑ sobre un comentario trae su etiqueta al inicio del cuadro y el comentario después.
"Edit" en un comentario en cola hace lo mismo y lo saca de la cola.

- El cursor no puede ir antes de la etiqueta. ⌫ al inicio del texto la quita, y el mensaje sale como uno normal.
- Copiar y pegar dejan la etiqueta fuera, así que nunca aparece dos veces ni en medio del texto. El cuadro lleva una
  etiqueta como máximo.
- Con la etiqueta al inicio, un "/" al comienzo del texto no es un comando.
- Para enviarlo hace falta texto: la etiqueta sola no se envía.

Al enviarlo, Rocky vuelve a leer las líneas de la etiqueta: las nuevas del archivo del worktree y las borradas de la
base. El código puede ser distinto del que salió la primera vez. Un comentario que editaste desde la cola también se
lee de nuevo: el código que guardaba se descarta.

- Si alguna línea ya no se puede leer (el archivo ya no existe, o el rango pasa del final), el bloque sale sin código:
  "Comment on src/openapi.ts, lines 18–25:" y el comentario.
- Si la conversación está en un turno, el comentario entra en su cola, como al enviarlo desde el diff.
- Los archivos que agregues junto a la etiqueta salen como enlaces después del bloque. En el bloque, cada uno aparece
  con su nombre.
- En la conversación se ve igual que el primer envío: la etiqueta arriba y el comentario debajo.

---

## 16. El editor

Rocky trae su propio editor de código. Aparece en:

- el modo Edit de una pestaña de diff;
- la pestaña de un archivo del worktree sin cambios (sección 17);
- las pestañas de código, datos y texto de archivos fuera del worktree, que abres desde el chat. Ahí un Markdown tiene
  Preview | Edit.

### Diff | Edit y "Unchanged"

- La pestaña de un archivo que está en Changes tiene **Diff | Edit** en el encabezado. Edit está apagado en un archivo
  borrado o binario.
- Un archivo sin cambios frente a la base abre solo en Edit, y el encabezado dice "Unchanged" en lugar de Diff | Edit.
  Su pestaña muestra el ícono del tipo de archivo.
- Si ese archivo cambia (lo guardas tú, o lo cambia el agente), entra en Changes: la pestaña gana la letra de estado y
  Diff | Edit, y sigue en Edit.

### Qué muestra

- Los números de línea, y la línea del cursor resaltada.
- Los colores de sintaxis (sección 14).
- Barras de cambio a la izquierda de los números, frente a la base: verde en líneas agregadas, ámbar en las
  modificadas y un triángulo rojo donde se borraron líneas. Siguen lo que escribes. Solo aparecen en archivos del
  worktree.
- Las líneas largas no se cortan. No hay autocorrección, comillas tipográficas ni corrector ortográfico.

### Teclas

- **⌘F** abre la barra de búsqueda de macOS. Esc la cierra, sin detener el turno del agente.
- **⌘L** (File ▸ Go to Line…) abre el campo "Go to line" encima del editor: escribe el número y pulsa Return. Esc
  vuelve al editor. Funciona también en una pestaña de vista previa (sección 17).
- Tab inserta la sangría que usa el archivo (espacios o tabuladores). Return mantiene la sangría de la línea.
- Deshacer y rehacer funcionan dentro de cada pestaña. El historial empieza de cero cada vez que la pestaña vuelve a
  mostrarse; el texto se queda.

### Guardar

- **⌘S** (File ▸ Save) o el botón Save guardan el archivo que tienes en pantalla.
- Con cambios sin guardar, el encabezado dice "Edited" junto a Save, y la pestaña muestra un punto en lugar de la ×.
- Si vuelves a Diff con cambios sin guardar, el diff muestra la versión guardada y el aviso "Unsaved edits · Save to
  see them here." con Save.
- Después de guardar, el diff y las barras de cambio se actualizan.
- ⌘S está apagado mientras Settings o los ajustes de un repositorio están abiertos, porque su Save usa ⌘S.

Rocky guarda el archivo sin cambiar su formato:

- Mantiene los finales de línea: un archivo con CRLF se guarda con CRLF, y uno mixto conserva cada línea como estaba.
- Nunca agrega ni quita el salto de línea del final. Conserva la marca de orden de bytes (BOM) de UTF-8.
- Mantiene los permisos (un script sigue siendo ejecutable) y los atributos extendidos.
- En un enlace simbólico, como los `.env` enlazados de la sección 4, escribe en el archivo destino: el enlace sigue
  siendo un enlace.

### Cuando el archivo cambia en el disco

Rocky vigila los archivos abiertos del worktree. Cuando el agente, un terminal o git cambian uno:

| Tu pestaña | Qué pasa |
| --- | --- |
| Sin cambios sin guardar | Rocky carga la versión nueva, y el encabezado dice "Reloaded" durante 2 segundos. |
| Con cambios sin guardar | Aparece el aviso "This file changed on disk." con Reload (descarta tus cambios y carga el archivo del disco) y Keep Mine (tu próximo guardado reemplaza el archivo del disco). |

**Rocky nunca reemplaza en silencio la versión del agente.** Antes de escribir, compara la fecha de modificación y el
contenido del archivo con los que leyó. Si cambiaron y no elegiste Keep Mine, no escribe nada y muestra el aviso.

- Keep Mine vale solo para la versión que viste. Si el archivo vuelve a cambiar, el aviso vuelve.
- Si el archivo se borra y no tienes cambios sin guardar, la pestaña dice "File not found". Con cambios sin guardar
  aparece el aviso, y Keep Mine seguido de Save lo vuelve a crear.
- Mientras el agente está en un turno, el editor muestra, con el nombre del agente, "Claude Code is working in this
  workspace and may change this file." La × lo cierra en esa pestaña.
- Queda un caso muy raro: si el agente escribe justo entre esa comparación y la escritura, tu versión queda encima de
  la suya.

### Cerrar una pestaña o salir con cambios sin guardar

- Al cerrar una pestaña con cambios sin guardar, Rocky pregunta "Save changes to openapi.ts?", con Save, Don’t Save y
  Cancel.
- Al salir de Rocky con cambios sin guardar, pregunta antes, aunque la ventana esté cerrada: "Save changes to 3 files
  before quitting?". Lista los archivos (hasta ocho, y cuenta el resto), con su workspace si son de varios. Los botones
  son Save All (Return), Cancel (Esc) y Don’t Save (⌘D). Con un solo archivo, el botón dice Save.
- Save All guarda cada archivo como lo haría ⌘S. Si alguno no se puede guardar (cambió en el disco, o falló la
  escritura), Rocky no sale y te muestra esa pestaña con su aviso.
- Rocky no guarda solo. Cerrar la ventana (⌘W) no cierra Rocky ni pierde tus cambios: siguen en sus pestañas.

---

## 17. All files: los archivos del worktree

La pestaña All files muestra el árbol de archivos del worktree. Cualquier archivo se abre desde ahí, con el mismo
visor y el mismo editor de las pestañas de diff.

### El árbol

- Primero las carpetas y luego los archivos, en el orden de Finder ("file2" antes que "file10").
- Un archivo que está en Changes lleva su letra (A, M o R). Una carpeta con archivos cambiados lleva un punto. Los
  archivos borrados no están en el árbol, porque ya no existen en el disco; Changes sí los lista.
- La fila del archivo que tienes en pantalla se ve seleccionada.
- Un clic en una carpeta la abre o la cierra. La primera vez solo se ve el primer nivel. Rocky recuerda las carpetas
  abiertas de cada workspace, también al relanzar. "⋯" ▸ Collapse All Folders las cierra todas.
- El árbol se actualiza solo cuando algo cambia en el disco. Un archivo nuevo puede tardar cerca de un segundo en
  aparecer.

Mientras lee, el árbol dice "Reading the files…". Si git falla, su error aparece en lugar del árbol.

Con el teclado, después de un clic en una fila:

| Tecla | Qué hace |
| --- | --- |
| ↑ / ↓ | Mueven la selección. |
| → | Abre la carpeta. Si ya está abierta, baja a su primer elemento. |
| ← | Cierra la carpeta, o sube a la carpeta que la contiene. |
| Return | Abre el archivo, como un clic. En una carpeta, la abre o la cierra. |

### Íconos de los archivos

Cada archivo lleva el ícono de su tipo, del tema Material Icon Theme de VS Code. Las carpetas conservan la carpeta
azul.

Rocky elige el ícono por la ruta del archivo, sin distinguir mayúsculas. Gana la primera regla que coincide:

1. Un `.yml` o `.yaml` dentro de `.github/workflows/` lleva el ícono de GitHub Actions.
2. El final de la ruta, para los pocos archivos que el tema reconoce con su carpeta, como `.config/graphqlrc`.
3. El nombre completo: `package.json`, `tsconfig.json`, `.gitignore`, `README.md`.
4. La extensión más larga que el tema conoce: `.test.ts` antes que `.ts`, y `.d.ts` también antes que `.ts`.
5. Si nada coincide, un ícono genérico de archivo.

El mismo ícono aparece en el árbol, en Quick Open, en las filas de Changes, en las pestañas de archivos sin cambios
(las de archivos cambiados muestran su letra de estado), en el encabezado de las pestañas, en los archivos de la
conversación y del cuadro de mensaje, y en la etiqueta de las líneas comentadas (sección 15). Los archivos ignorados
lo muestran atenuado, igual que su nombre. Los íconos siguen el zoom de la ventana (⌘+ y ⌘-).

Los íconos son de Material Icon Theme 5.38.1 (licencia MIT, © 2025 Material Extensions) y vienen dentro de Rocky: no
se descarga nada al usarlo.

### Archivos ignorados

- Rocky oculta lo que git ignora: `node_modules`, `dist`, `.env`, `.DS_Store`… Los archivos que empiezan con punto y
  que git sigue (`.github`, `.gitignore`) se ven como cualquier otro. `.git` nunca aparece.
- "⋯" ▸ Show Ignored Files muestra los ignorados, atenuados. Rocky recuerda esa opción para cada repositorio.
- El filtro nunca busca entre los archivos ignorados.

### Filtrar

1. Escribe en el campo "Filter files", arriba del árbol. Para buscar un archivo desde cualquier parte, sin abrir el
   panel, usa Quick Open (⌘P, más abajo).
2. El árbol se cambia por una lista de los archivos que coinciden: ícono, nombre, carpeta y letra de estado. Las
   letras que coinciden se ven resaltadas.
3. ↓ / ↑ recorren los resultados, y Return abre el elegido. Con el campo vacío, ↓ pasa al árbol.
4. Esc borra el texto, y el árbol vuelve como estaba. Un segundo Esc sale del campo.

Los resultados van en este orden, sin distinguir mayúsculas:

1. El nombre empieza con lo que escribiste.
2. El nombre lo contiene.
3. La ruta lo contiene.
4. Las letras aparecen en orden en el nombre: "srv" encuentra `server.ts`.
5. Las letras aparecen en orden en la ruta.

Si dos empatan, van en el orden de Finder. Sin resultados, la lista dice "No file matches “srv”". Mientras escribes en
el filtro, Esc no detiene el turno del agente.

### Quick Open (⌘P)

Quick Open busca un archivo del worktree desde cualquier parte de la ventana, sin tocar el panel derecho.

1. Pulsa ⌘P (File ▸ Go to File…), también desde el cuadro de mensaje, el editor o un terminal. ⌘P ocupa el lugar de
   File ▸ Print, que Rocky no usa.
2. Aparece un panel arriba, al centro de la ventana, con el campo "Search project files…" listo para escribir. El
   panel derecho queda como estaba, abierto o cerrado.
3. Escribe parte del nombre o de la ruta. Los resultados siguen el mismo orden que el filtro de All files, y dentro de
   cada grupo van primero los archivos que abriste hace poco. Las letras que coinciden se ven resaltadas.
4. ↓ / ↑ mueven la selección; desde la última fila, ↓ vuelve a la primera. Pasar el mouse sobre una fila también la
   selecciona.
5. Return abre el archivo elegido en una pestaña normal, y ⌥Return lo abre como vista previa. Con el mouse: un clic
   abre, y ⌥-clic abre como vista previa. Los botones de abajo, "Open ↩" y "Open as preview ⌥↩", hacen lo mismo.

Esc, un clic fuera del panel o ⌘P otra vez lo cierran. Mientras está abierto, Esc no detiene el turno del agente.

Con el campo vacío, la lista muestra, en este orden:

1. Los archivos que abriste hace poco en este workspace, del más reciente al más antiguo, con un reloj.
2. Los archivos cambiados que no están entre ellos, con su letra de estado.
3. Todos los demás, en el orden de Finder.

- "Recientes" son los últimos 20 archivos que abriste en una pestaña de este workspace: desde el árbol, Changes, una
  etiqueta del chat o Quick Open. Rocky los recuerda al relanzar, y quitar el workspace los borra.
- Quick Open nunca lista los archivos ignorados.
- La primera vez, o si algo cambió en el disco desde la última lectura, Quick Open lee la lista de archivos al abrirse
  y muestra "Reading files…". Escribir no lanza ningún proceso.

### Pestañas de vista previa

1. Un clic en un archivo (o Return) lo abre en una **pestaña de vista previa**, con el título en cursiva. En Quick Open
   es ⌥Return o ⌥-clic.
2. La siguiente vista previa la reemplaza. Así, recorrer el árbol no llena la fila de pestañas. Un archivo que abres
   para quedarte (Return en Quick Open) abre su propia pestaña y deja la vista previa como estaba.
3. Para quedarte con ella: doble clic en el archivo, doble clic en la pestaña, o tu primer cambio en el texto.

- La vista previa no toma el teclado, así que las flechas siguen moviéndose por el árbol.
- Un archivo en Changes abre su pestaña de diff en modo Diff. Cualquier otro abre en Edit, con "Unchanged"
  (sección 16).
- La pestaña Changes y las etiquetas del chat abren pestañas normales, nunca de vista previa.

### Reveal in All Files

El menú "⋯" de la pestaña de un archivo del worktree tiene "Reveal in All Files" (salvo si el archivo está borrado).
Abre el panel en All files, borra el filtro, abre las carpetas del archivo y lo muestra en el árbol. En el árbol,
"⋯" ▸ Reveal Active File hace lo mismo con la pestaña que tienes en pantalla. Sin una, está apagado: "No worktree file
is showing".

### Archivos grandes y binarios

Rocky mira el tamaño del archivo antes de leerlo:

| Archivo | La pestaña muestra |
| --- | --- |
| Texto de hasta 2 MB | El editor. |
| Texto de 2 a 20 MB | El editor en solo lectura y sin colores, con el aviso "Large file · 3.4 MB · read-only in Rocky". |
| Más de 20 MB | No lo carga: "Too large to open in Rocky · 48 MB", con Open in Finder y un botón "Open in …" por cada editor instalado (Antigravity, Cursor, VS Code o Zed), que abre ese archivo. |
| Imagen o PDF | La imagen, o el PDF en la vista rápida de macOS. |
| Otro binario | "Binary file · 112 KB" y Open in Finder. |

Binario quiere decir que tiene un byte NUL en sus primeros 8 KB. Un archivo de más de 20 MB es "Too large", sea texto
o no. Las pestañas que abres desde el chat siguen las mismas reglas.

---

## 18. Hacer commit desde Rocky

Rocky puede hacer el commit él mismo, sin el agente. Sirve, por ejemplo, para tus propios cambios hechos en el editor.
El "Commit and push" del panel (sección 11), en cambio, se lo pide al agente.

1. En la pestaña Changes, pulsa "Commit…" en el grupo UNCOMMITTED.
2. Se abre la hoja "Commit changes", con los archivos sin commit (solo para leer).
3. Escribe el asunto en "Subject". Viene con el título del workspace, si ya tiene uno. Un contador cuenta hasta 72
   caracteres y se pone ámbar si te pasas; el commit se hace igual.
4. Si quieres, escribe una descripción en "Description (optional)".
5. Pulsa Commit o ⌘Return. Commit está apagado mientras el asunto está vacío. Cancel o Esc cierran la hoja.

Rocky corre `git add -A` y después `git commit`, en el worktree y con las variables del workspace:

- `git add -A` toma todo, también un archivo que el agente agregue mientras la hoja está abierta.
- **Los hooks de git siempre corren**: Rocky nunca usa `--no-verify`. Lo que escriben aparece en la hoja mientras
  corren, bajo "Running git commit…". Mientras git corre, la hoja no se puede cerrar.
- Si el commit sale bien, la hoja se cierra, aparece el aviso "Committed" y Changes se actualiza.
- Si falla, la hoja queda abierta con el error (por ejemplo "git commit exited 1") y lo que escribieron git y los
  hooks. Tu mensaje se queda: corrige el problema y pulsa Commit otra vez.
- Con un rebase o un merge a medias en el worktree, Rocky no hace el commit ni agrega nada: "A rebase or a merge is in
  progress in this worktree. Finish it first."

El commit usa la identidad de git que tengas configurada. M4 traerá una identidad por cuenta.

---

## 19. Atajos de teclado

| Atajo | Qué hace | Dónde |
| --- | --- | --- |
| ⌘, | Abre Settings | Menú Rocky |
| ⌘N | Nuevo workspace | Menú File |
| ⌘O | Abre el worktree en la app por defecto (Open in …) | Menú File |
| ⌘S | Guarda el archivo en pantalla (Save) | Menú File |
| ⌘P | Go to File: abre o cierra Quick Open | Menú File |
| ⌘L | Go to Line: va a una línea del editor | Menú File |
| ⌘K | Busca workspaces | Menú View |
| ⌘1 … ⌘9 | Selecciona el workspace visible número N | Menú View |
| Mantener ⌘ | Muestra el atajo de cada fila | Barra lateral |
| ↑ / ↓ | Mueven la selección | Barra lateral, con la lista enfocada |
| ⌃⌘S | Muestra u oculta la barra lateral | Menú View |
| ⌥⌘B | Muestra u oculta el panel derecho | Menú View |
| ⌘⇧C | Muestra el panel derecho en Changes, o lo oculta si Changes ya se ve | Menú View |
| ⌥⌘↓ / ⌥⌘↑ | Archivo cambiado siguiente / anterior | Menú View |
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
| ⌘-clic en el número del PR | Abre el PR en GitHub | Panel derecho |
| ↑ / ↓, →, ←, Return | Mover, abrir carpeta, cerrarla o subir, abrir archivo | Árbol de All files |
| ↑ / ↓, Return, Esc | Recorrer resultados, abrir, borrar el texto (un segundo Esc sale) | Filtro de All files |
| ↑ / ↓, Return, ⌥Return, Esc | Mover (da la vuelta), abrir, abrir como vista previa, cerrar | Quick Open |
| ⌘F | Busca en el archivo | Editor |
| Tab | Inserta la sangría del archivo | Editor |
| ⌘Return | Envía el comentario | Cuadro de comentario |
| Esc | Cierra el cuadro (pregunta antes si tiene texto) | Cuadro de comentario |
| ⌘Return | Hace el commit | Hoja de commit |
| Esc | Cancela | Hoja de commit |
| Return, Esc, ⌘D | Save All, Cancel, Don’t Save | Aviso de cambios sin guardar al salir |

---

## 20. Energía

Rocky está hecho para gastar poca batería, incluso con muchos workspaces abiertos.

- **Nada consulta nada en reposo.** Rocky no revisa el disco con temporizadores. Cada workspace tiene un flujo de
  FSEvents sobre su worktree y su carpeta de git (sin `node_modules` ni `.git/objects`), que no lanza procesos. Git
  corre solo después de un evento: un cambio en el disco (Rocky los agrupa cada medio segundo), seleccionar un
  workspace, volver a la ventana, una acción tuya o el fin de un turno.
- **Git calcula solo lo que se ve.** Tras un cambio, Rocky cuenta las líneas del workspace para la barra lateral.
  El diff completo es solo para el workspace seleccionado, mientras muestra Changes, All files, Quick Open o una
  pestaña de diff. `git ls-files` corre solo mientras se ve All files, o al abrir Quick Open si algo cambió desde la
  última lectura, y el árbol lee solo las carpetas abiertas.
- **Las animaciones se pausan solo cuando la ventana no se ve** (minimizada, oculta, tapada o en otro Space). Con
  Rocky visible detrás de otra app siguen, para que un agente que trabaja no parezca congelado. El círculo de carga
  usa Core Animation; el texto brillante de "Working" es el único costo visible (hasta 30 cuadros por segundo).
- **GitHub no lanza procesos.** Cada refresco es una petición `URLSession` a GitHub, y dos mientras la pestaña Checks
  muestra los comentarios de un PR abierto. `gh` solo corre para leer las cuentas y los tokens, una vez por sesión.
- **Los agentes arrancan cuando hacen falta:** el de la conversación en pantalla, y los demás al abrirlos o al recibir
  un comentario en líneas (sección 15).
- **Las actualizaciones de agentes** se consultan una vez al día, con una petición HTTPS a npm.

Para medir el consumo:

```
scripts/energy-report.sh 30
```

Compara Rocky con Conductor en los últimos 30 minutos, con datos del registro de energía de macOS: energía, segundos
de CPU y procesos iniciados (en total y por minuto). El registro se escribe con retraso, así que los últimos minutos
pueden faltar. El objetivo en reposo es menos de 5 procesos por minuto.

---

## 21. Problemas comunes y qué hacer

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

### "This file changed on disk."

El archivo cambió en el disco (el agente, un terminal o git) mientras tenías cambios sin guardar. Rocky no escribió
nada.

1. Si quieres la versión del disco, pulsa Reload. Tus cambios se descartan.
2. Si quieres la tuya, pulsa Keep Mine y guarda con ⌘S. Tu versión reemplaza la del disco.

Si el agente sigue trabajando en ese archivo, espera a que termine el turno antes de guardar.

### "Large file · … · read-only in Rocky" o "Too large to open in Rocky"

El archivo pasa de 2 MB (Rocky lo muestra sin dejarte editarlo) o de 20 MB (Rocky no lo carga). Para editarlo, usa
otro editor: en una pestaña del worktree, "⋯" ▸ Open in Finder; pasados los 20 MB, también los botones "Open in …" de
la pestaña.

### Un archivo de texto aparece como "Binary file"

Rocky solo lee texto en UTF-8. Un archivo en otra codificación (por ejemplo, Latin 1) aparece como "Binary file", con
Open in Finder. Ábrelo en otro editor.

### El commit falla por un hook

La hoja de commit sigue abierta con el error, por ejemplo "git commit exited 1", y lo que escribió el hook. Tu mensaje
se conserva.

1. Lee la salida del hook en la hoja.
2. Corrige lo que pide, en el editor o en un terminal.
3. Pulsa Commit otra vez. Rocky nunca salta los hooks.

### "A rebase or a merge is in progress in this worktree. Finish it first."

Hay un rebase o un merge a medias en el worktree, y Rocky no hace commits ahí. Mientras dure, Changes tampoco se
actualiza.

1. Termínalo o cancélalo en un terminal (`git rebase --continue` o `git rebase --abort`; `git merge --continue` o
   `git merge --abort`), o pídeselo al agente.
2. Vuelve a abrir la hoja de commit.

### Un error de git en la pestaña Changes

Git falló al leer los cambios o al descartar un archivo; por ejemplo, un descarte mientras otro `git` tenía el índice
bloqueado. Sus últimas líneas aparecen en rojo en la pestaña Changes.

1. Espera a que termine el otro proceso (un `git` del agente o de un terminal).
2. Cierra el error con × y prueba otra vez, o usa "⋯" ▸ Refresh.

### Un `.env` enlazado no se recarga en el editor

Rocky vigila el worktree, no el clon principal. Si cambias un `.env` enlazado desde el clon principal, su pestaña no se
entera. Cierra la pestaña y ábrela otra vez.

### Una carpeta ignorada abierta no se actualiza

Con Show Ignored Files, Rocky no recibe avisos de cambios dentro de `node_modules`. Ciérrala y ábrela: Rocky la vuelve a
leer cada vez que la abres.

### Dónde están los logs

- `~/Library/Logs/Rocky`: lo que cada agente escribe en stderr. Settings → Data → Logs lo abre en Finder.
- `~/Library/Application Support/Rocky/ci-logs`: los logs de CI que "Fix errors" adjuntó.
- La salida de los scripts está en sus pestañas del panel inferior mientras Rocky esté abierto.

---

## 22. Próximamente

- **M2.8, conversaciones:** "+" abre una conversación enseguida con el último agente usado en el repositorio, y el
  agente se elige desde el menú de modelos.
- **M4, cuentas y energía:** la identidad de git y la llave SSH de cada cuenta, y la medición de energía de Rocky
  frente a Conductor.

---

Esta guía se actualiza con cada nueva función de Rocky. Si algo de la app no coincide con lo que dice aquí, la guía
está desactualizada: avisa para corregirla.
