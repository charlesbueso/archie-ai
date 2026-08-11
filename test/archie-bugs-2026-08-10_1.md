# Archie — Reporte de bugs

**Sesión:** 10 de agosto 2026, ~21:30–22:15
**Versión:** archie_mcp 0.2.0 / extensión 0.2.0
**Entorno:** SketchUp 25.0.575, Ruby 3.2.2, Windows, puerto 9876, `dev_mode=false`
**Modelo de prueba:** `CASA CUMBRES DE JUAREZ_original.skp` (672 contenedores, 502 definiciones, 7 niveles N0–N6, 12 losas)
**Contexto:** primera sesión de uso real end-to-end, con usuario no experto en SketchUp.

---

## P0 — Bloqueantes

### BUG-01 · `create_snapshot` hace dedup contra un hash obsoleto

**Severidad:** crítica. Anula toda la red de seguridad del producto.

Todos los `create_snapshot` de la sesión (manuales y automáticos previos a mutación) respondieron `deduped: true, identical_to: "<snapshot inicial>"` con `edit_seq: 1` congelado — incluso inmediatamente después de mutaciones verificadas como exitosas.

**Evidencia dura:** al final de la sesión, `save_model` generó su propio snapshot (`auto disk state before save`) con `sha256: c63512f84e52...` y `85,505,142 bytes`. El snapshot inicial tenía `sha256: e885ce206188...` y `85,504,255 bytes`. El archivo en disco **no era idéntico**, pero `create_snapshot` insistía en que sí.

Conclusión: hay dos rutas de código calculando el hash. La de `save_model` lo calcula real; la de `create_snapshot` compara contra un valor cacheado que nunca se recalcula.

**Evidencia secundaria:** `get_model_info` reportaba `modified: true` en el mismo momento en que los snapshots decían "sin cambios".

**Sospecha adicional:** la docstring de `create_snapshot` promete capturar el estado *"including unsaved changes"*. Verificar si realmente serializa memoria o solo copia el `.skp` de disco. Si es lo segundo, todos los auto-snapshots capturan el último guardado, no el estado previo real a la mutación.

**Comparación útil:** en las corridas de smoke test de las 13:57–14:06 el `edit_seq` sí avanzaba 1→2→3→4→5 correctamente. Vale la pena diffear qué cambió entre esas corridas y esta sesión.

**Repro:**
1. `create_snapshot("A")`
2. `resize_opening(...)` → confirmar `verified: true`
3. `create_snapshot("B")` → devuelve `deduped: true, identical_to: A` (incorrecto)
4. `save_model()` → su snapshot interno muestra un sha distinto al de A

---

### BUG-02 · Mutaciones con `verified: false` no se revierten

**Severidad:** crítica.

Cuando la verificación posterior falla, la geometría queda modificada de todos modos, en estado potencialmente inválido. No hay rollback.

Casos observados:
- `resize_opening` pidió 1.30 × 2.60 → aplicó 1.121 × 2.66 con sill desplazado. `verified: false`, geometría alterada.
- `set_slab_thickness(thickness=-0.5)` → invirtió la losa. `verified: false`, geometría alterada.
- `set_slab_thickness(thickness=500)` sobre losa degenerada → la teletransportó a z=-499.5. `verified: false`, geometría alterada.

**Esperado:** si `verified` falla, revertir la transacción y devolver error explicando por qué no se pudo cumplir el objetivo.

---

### BUG-03 · `set_slab_thickness` no valida el parámetro `thickness`

**Severidad:** crítica (corrupción de datos).

| Input | Resultado | `verified` |
|---|---|---|
| `-0.5` | Losa invertida: de `-0.35→0.0` pasó a `0.0→0.5` | `false`, aplicado |
| `0` | Losa degenerada, volumen nulo (`z_bottom == z_top == 0.5`) | **`true`** ← lo reporta como éxito |
| `500` | Losa teletransportada a `z=-499.5`, espesor sigue en 0.0 | `false`, aplicado |

El caso `0` es el más grave: crea geometría degenerada y la marca como correcta.

**Fix:** validar `0 < thickness <= <máximo razonable>` (¿2m?) antes de tocar nada.

---

### BUG-04 · Corrupción silenciosa: losa degenerada desaparece del inventario

**Severidad:** crítica.

Tras degenerar `pid 2481304`, `get_model_info` pasó de reportar 12 losas a 11. La losa ya no aparece, pero su geometría sigue existiendo en el modelo (flotando a 500m bajo el terreno).

Un arquitecto quedaría con geometría huérfana invisible, sin forma de encontrarla ni repararla desde Archie.

**Fix:** reportar losas degeneradas o anómalas con una bandera (`degenerate: true`, `anomaly: "zero_thickness"`) en vez de omitirlas.

---

## P1 — Alto impacto

### BUG-05 · Clasificación DOOR/WINDOW/ASSEMBLY inestable entre llamadas

Una misma abertura cambia de tipo sin que su geometría cambie:

- `2754110:2.30,14.25,1.86` → `list_openings` la reporta `WINDOW`; `resize_opening` la rechaza como `ASSEMBLY`. Contradicción directa entre dos tools sobre la misma abertura.
- `80482:9.11,10.54,4.67` cambió de `DOOR` a `ASSEMBLY` **sin haber sido tocada**, tras editar otra abertura del mismo contenedor. Tras el restore, volvió a `DOOR`.

**Causa probable:** el clasificador re-analiza todo el contenedor y la nueva geometría cambia cómo agrupa recesos vecinos.

**Impacto:** hace imposible construir flujos confiables. Yo (el agente) no puedo confiar en el `kind` que me devuelve el listado.

---

### BUG-06 · Editar una abertura fusiona a sus vecinas y las vuelve ineditables

**Repro exacto:**
1. Estado inicial: dos puertas de balcón adyacentes, `80482:9.41,27.62,4.77` (0.78m) y `80482:10.27,27.44,4.77` (0.83m), ambas con sill 0.03, head 2.37.
2. `resize_opening` sobre la primera → alto 2.70, sill 0. `verified: true`. Correcto.
3. `list_openings` → la segunda puerta ya no existe como entidad propia. En su lugar aparece un `ASSEMBLY` de 1.66m centrado en X=9.85 que abarca a ambas.
4. Cualquier intento de editar la segunda falla con *"this is a multi-light ASSEMBLY"*.

**Resultado:** imposible dejar un par de puertas simétricas. Se puede editar una y la otra queda bloqueada permanentemente.

**Causa probable:** al igualar los sills, el detector de recesos une ambos huecos en una región contigua.

---

### BUG-07 · Losas detectadas pero inmutables (desajuste bbox vs. entidades directas)

`get_model_info` reporta `Group#212` (pid 2482624) como losa de `z=0.0` a `z=0.32`.
`set_slab_thickness` falla con: *"no vertices found at z=0.0 (tolerance 0.02m)"*.
Probado con `datum='top'` y `datum='bottom'` — **ambas caras fallan**.

**Hipótesis:** `get_model_info` detecta la losa por bounding box (que incluye geometría anidada), mientras `set_slab_thickness` solo recorre las entidades directas del grupo (11 en este caso). Las caras reales viven un nivel más adentro.

**Impacto:** el usuario ve una losa listada, la intenta modificar, y recibe un error que contradice al otro tool.

**Fix:** o bien recorrer recursivamente en `set_slab_thickness`, o bien marcar en `get_model_info` qué losas son editables (`editable: false, reason: "nested_geometry"`).

---

### BUG-08 · `create_project` sobreescribe silenciosamente el `model_path`

Re-registrar un proyecto existente con una ruta distinta repunta el proyecto sin advertencia ni confirmación, devolviendo el mismo `id`.

**Riesgo real:** un usuario que teclee mal la ruta repunta su proyecto sin darse cuenta; después `open_project` o `save_model` operan sobre el archivo equivocado — potencialmente escribiendo cambios dentro de `.archie/versions/`.

**Probado:** repunté "Casa Cumbres de Juárez" a un archivo de snapshot. Aceptado sin protesta.

**Fix:** o rechazar el cambio de ruta, o exigir un flag explícito (`allow_repoint=true`), o devolver `updated: true` para que quien llama pueda avisar.

---

### BUG-09 · `create_project` no valida que el `.skp` exista

La docstring dice *"The model file must already exist"*, pero acepta cualquier ruta. El error aparece mucho después, al intentar `open_project`.

Inconsistencia interna notable: el mismo tool **sí** valida que el cliente exista (`client 'X' not found — create_client first`), pero no el archivo. Y `list_projects` ya calcula `model_exists` — la infraestructura está, solo no se usa en el punto correcto.

---

## P2 — Fricción y calidad

### BUG-10 · `restore_version` exige "Do not save changes" manual

Cada restore dispara el diálogo modal de SketchUp y obliga al usuario a hacer clic. En el flujo natural de trabajo (probar → restaurar → probar) esto se repite constantemente y rompe la promesa de automatización.

**Fix:** descartar cambios vía API antes de reabrir (`model.close(true)` o equivalente), o al menos documentar el comportamiento y ofrecer un parámetro `discard_unsaved=true`.

---

### BUG-11 · Matching de nombres sensible a acentos

- `"Casa Cumbres de Juarez"` → **no encuentra** `"Casa Cumbres de Juárez"`
- `"casa cumbres de juárez"` → **sí encuentra**

Hace `.lower()` pero no normalización Unicode. Para un producto mexicano esto va a doler: usuarios y agentes escribimos sin acentos constantemente.

**Fix:** normalizar NFD + strip de diacríticos en ambos lados de la comparación. Aplica a `get_project_brief`, `set_project_brief`, `open_project`, `create_project`, `list_projects`, `create_client`.

---

### BUG-12 · `list_openings` con `container_pid` inexistente devuelve vacío en silencio

`list_openings(container_pid=99999999)` → resultado vacío, sin error.
`set_slab_thickness(slab_pid=99999999)` → error explícito `container pid not found`.

Inconsistencia peligrosa: yo podría concluir "esta pared no tiene aberturas" cuando en realidad el pid estaba mal.

---

### BUG-13 · Sin validación en filtros de `list_openings`

`min_width=-10, min_height=-5` aceptados sin protesta. Devuelve ~180 aberturas.

---

### BUG-14 · El detector de aberturas no distingue muros de mobiliario

Con filtros bajos aparecen como "ventanas":

- `/living+room/West Elm Mobile Chandelier Large/Group#1047/Group#1045/Group#1038/Group#1033/Group#1028` — 0.02 × 0.02m, clasificado `WINDOW`. **Es una pieza de un candelabro.**
- Huecos dentro de sofás y componentes de mobiliario, varios de 0.02–0.06m.
- `/Group#94/Group#3` y `/Group#94/Group#2` — elementos con `sill_above_floor: -0.19` (bajo el nivel de piso).

El filtro default de 0.5m es lo único que oculta esto. La detección no tiene noción de "¿este contenedor es un muro?".

**Fix sugerido:** filtrar por contexto del contenedor (¿es parte de un sólido tipo muro?), o excluir componentes con nombres de mobiliario, o exigir un espesor mínimo de pared alrededor del hueco.

---

### BUG-15 · Aberturas con antepecho negativo sin marcar

Varias con `sill_above_floor` negativo (hasta `-0.19`), es decir huecos por debajo del piso terminado. Se reportan como aberturas normales sin bandera de anomalía.

---

### BUG-16 · No existen tools de borrado

No hay `delete_project` ni `delete_client`. "Proyecto Fantasma" creado durante estas pruebas queda permanentemente en la base de datos apuntando a una ruta inexistente, sin forma de limpiarlo desde Archie.

**Pendiente de limpieza manual:** proyecto id=2 "Proyecto Fantasma", cliente id=1 "Testing Interno".

---

### BUG-17 · `eval_ruby` devuelve el error como resultado exitoso

```json
{"error": "eval_ruby is disabled (dev_mode=false in ~/Archie/config.json)"}
```

El resto de los tools lanzan `RuntimeError`. Un cliente que solo revise excepciones interpretaría esto como éxito. Unificar la superficie de errores.

---

### BUG-18 · `create_snapshot` con dedup omite el campo `file`

Cuando deduplica, la respuesta no incluye a qué archivo quedó asociado el snapshot. Quien llama no puede saber dónde quedó.

---

### BUG-19 · Esquema inconsistente en `list_versions`

Entre entradas de la misma lista:
- `model_guid` aparece solo en una versión
- `edit_seq` falta en algunas (incluida la generada por `save_model`)
- `tool` falta en las manuales
- El label `"auto disk state before save"` genera el archivo `--disk-state-before-save.skp` (se pierde el prefijo "auto")

---

### BUG-20 · `dry_run` no simula el clamping

`resize_opening(dry_run=true)` devuelve el `target` solicitado como si fuera alcanzable, sin advertir que se aplicará clamp. Luego la ejecución real logra algo distinto.

Esto vuelve inútil el dry-run justo para su caso de uso principal: previsualizar antes de comprometerse.

**Fix:** el dry-run debe correr la misma lógica de clamping y devolver el `achieved` proyectado.

---

## Problemas de diseño (no bugs, pero importantes)

### DESIGN-01 · El output de `list_openings` revienta el contexto

Una sola llamada sin filtros devolvió ~180 objetos JSON verbosos. En una sesión real esto consume una fracción enorme de la ventana de contexto del agente y deja poco espacio para razonar sobre el problema del usuario.

**Sugerencias:**
- Paginación (`limit` / `offset`)
- Modo resumen: conteo por `kind` y agrupado por contenedor
- Filtro por tipo: `kind="DOOR"`
- Omitir campos redundantes (`ffl_z` se repite en cada entrada; `center` duplica info del `id`)

---

### DESIGN-02 · No hay forma de crear geometría nueva

Solo existen tools para modificar losas y aberturas existentes. Peticiones naturales de un arquitecto — *"agrega una alberca atrás"*, *"mete un muro aquí"* — no tienen camino.

Con `eval_ruby` desactivado en beta, no hay escape hatch. Vale la pena decidir si esto es alcance deliberado del MVP o un gap a llenar.

---

### DESIGN-03 · No hay forma de localizar geometría desde Archie

Todo el flujo de esta sesión dependió de que el usuario encontrara manualmente una ventana en SketchUp, orbitando y haciendo clic por aproximación. Costó ~6 intentos con un usuario no experto.

Los grupos no tienen nombres, así que el buscador del Outliner no sirve. `get_selection` ayuda a verificar *después* del clic, pero no a guiar *antes*.

**Sugerencia:** un tool `zoom_to(pid)` o `highlight(pid)` que mueva la cámara de SketchUp al elemento. Convertiría el flujo de "adivina y verifica" en "yo te lo señalo". Probablemente el mayor salto de usabilidad disponible ahora mismo.

---

## Lo que funcionó bien

- **`health_check`** — claro y completo, buen punto de entrada.
- **`resize_opening` en aberturas aisladas** — `verified: true` con precisión exacta. El caso `2.70m` salió perfecto. El motor funciona; el problema son los vecinos.
- **`set_slab_thickness` con `datum='top'`** en losas bien formadas — semántica correcta (mantiene el nivel de piso, mueve el sofito), `verified: true`.
- **`restore_version`** — restauró fielmente el estado, incluyendo revertir clasificaciones alteradas. Confiable.
- **Inyección SQL** — bien manejada. Cadenas parametrizadas; el payload `'; DROP TABLE projects; --` se guardó literal y la tabla quedó intacta.
- **Unicode** — acentos, emojis y CJK preservados correctamente en briefs.
- **Mensajes de error accionables** — `client 'X' not found — create_client first (existing: [...])` es exactamente el estilo correcto.

---

## Orden sugerido de ataque

1. **BUG-01** (snapshots) — sin esto, nada más es seguro de arreglar.
2. **BUG-02 + BUG-03** (rollback + validación) — detienen la corrupción.
3. **BUG-05 + BUG-06** (clasificación y fusión) — es lo que rompe el caso de uso central.
4. **DESIGN-03** (`zoom_to`) — el mayor salto de usabilidad por esfuerzo invertido.
5. El resto en orden de aparición.
