# Archie v0.3.0 — respuesta al reporte de bugs del 10 de agosto

Responde a [`test/archie-bugs-2026-08-10_1.md`](../test/archie-bugs-2026-08-10_1.md).
Suite de regresión: `tools/smoke_bugs.py` (rápida, solo lectura) —
un check por número de bug, para que una regresión sea evidente.

**Estado: 19 de 20 bugs corregidos y verificados. 1 pendiente (BUG-06).**

---

## Causas raíz encontradas

### BUG-01 — el observador de transacciones se moría por garbage collection

La hipótesis del reporte ("dos rutas calculando el hash") iba bien encaminada
pero el mecanismo era otro. El código hacía:

```ruby
model.add_observer(EditCounter.new)   # ← nadie guarda la referencia
```

SketchUp no retiene la instancia del lado Ruby: el recolector de basura se la
lleva y **los callbacks dejan de dispararse para siempre, en silencio**. Por eso
`edit_seq` se quedó congelado en 1 y todo snapshot posterior dedupeaba contra el
inicial. En las corridas de smoke test de las 13:57 sí avanzaba porque el
observador acababa de crearse y aún no había sido recolectado.

Verificado con una sonda: el mismo observador con referencia retenida dispara
correctamente (`hits=1`); sin referencia, `seq 1 -> 1`.

**Corrección, en tres capas:**
1. `@observers[model.object_id] = obs` mantiene viva la instancia.
2. Las herramientas que mutan llaman `Versioning.bump!` **directamente**, así la
   corrección de los snapshots nunca depende solo del observador. El observador
   ahora solo sirve para detectar ediciones que hace *el usuario* en SketchUp.
3. `get_model_ref` reporta `observer_alive`, y el lado Python **se niega a
   dedupear** si el observador no está vivo. Falla hacia tomar un snapshot de
   más, nunca de menos.

**Sobre la sospecha del reporte:** `create_snapshot` sí serializa memoria
(`model.save_copy`), no copia el disco. Y el detalle de los sha distintos tiene
otra explicación: `save_copy` re-serializa el modelo e incrusta un timestamp, así
que **dos copias de un modelo idéntico nunca son iguales byte a byte**. Por eso
el hash no puede ser la llave de dedup y el contador de transacciones sí.

### BUG-05 — los dos tools clusterizaban con umbrales distintos

`list_openings` agrupaba con `min 0.5`; el `find_cluster` interno de
`resize_opening` con `0.15`. Distinto conjunto de loops → distinta detección de
`ASSEMBLY` → **los dos tools opinaban distinto sobre la misma abertura**.

Ahora todo clusteriza con un piso canónico único (`CANON_MIN = 0.05`) y el
filtro del usuario se aplica **solo a la presentación**. Verificado: 16 aberturas
comparadas, 16 coincidencias, 0 discrepancias.

---

## Tabla de estado

| Bug | Estado | Qué se hizo |
|---|---|---|
| **01** snapshots dedupean mal | ✅ verificado | Referencias de observador retenidas + `bump!` explícito + Python no dedupea si el observador está muerto |
| **02** mutación sin rollback | ✅ corregido | La verificación corre **dentro** de la operación; si falla, `abort_operation` revierte y el tool lanza error. Una mutación ya no sobrevive a su propia verificación fallida |
| **03** `thickness` sin validar | ✅ verificado | `0 < t <= 3.0 m`; `-0.5`, `0` y `500` rechazados antes de tocar geometría |
| **04** losa degenerada desaparece | ✅ verificado | Ya no se omite: se reporta con `anomalies: ["zero_thickness"]`. En tu modelo aparecen **2 losas anómalas** que antes eran invisibles |
| **05** clasificación inestable | ✅ verificado | Umbral de clustering canónico único (arriba) |
| **06** editar fusiona vecinas | ⚠️ **pendiente** | Ver abajo |
| **07** losas detectadas pero inmutables | ✅ corregido | `set_slab_thickness` ahora recorre geometría anidada; `get_model_info` reporta `editable`, `nested_geometry` y `not_editable_reason`. En tu modelo: 3 losas anidadas, ahora editables |
| **08** repunte silencioso de `model_path` | ✅ verificado | Requiere `allow_repoint=true`; devuelve `repointed: true` |
| **09** no valida que el `.skp` exista | ✅ verificado | Valida existencia y extensión al crear |
| **10** restore exige clic manual | ✅ corregido | `discard_unsaved` limpia la bandera de modificado antes de reabrir (seguro: siempre hay snapshot previo) |
| **11** matching sensible a acentos | ✅ verificado | Normalización NFD + strip de diacríticos en clientes y proyectos. `Juarez` encuentra `Juárez` |
| **12** pid inexistente → vacío | ✅ verificado | Ahora lanza `container pid N not found in this model` |
| **13** filtros sin validar | ✅ verificado | Rechaza negativos; valida `kind` |
| **14** mobiliario como ventanas | ✅ verificado | Contenedores con envergadura < 1 m no pueden ser muros: excluidos por defecto, contados en `furniture_excluded`, visibles con `include_furniture=true` |
| **15** antepecho negativo sin marcar | ✅ verificado | `anomalies: ["negative_sill"]`, más `thin_host` |
| **16** sin tools de borrado | ✅ verificado | `delete_project` y `delete_client` (con guardia contra borrar un cliente que aún tiene proyectos). **"Proyecto Fantasma" ya fue eliminado** |
| **17** `eval_ruby` devuelve error como éxito | ✅ corregido | Ahora lanza `PermissionError`, igual que el resto |
| **18** dedup omite `file` | ✅ corregido | La respuesta incluye `file`, `identical_to` y `reason` |
| **19** esquema inconsistente | ✅ corregido | Un solo escritor de manifest (`snapshot_disk_state`); todas las entradas con las mismas llaves |
| **20** `dry_run` no simula clamping | ✅ verificado | `dry_run` corre la misma planeación y devuelve `projected` + `clamped` |
| **DESIGN-01** contexto reventado | ✅ verificado | `list_openings` devuelve `{total, by_kind, ...}` con `summary=true`, `kind=`, `limit`/`offset`. El resumen cabe en dos líneas |
| **DESIGN-02** no se puede crear geometría | ⏸ diferido | Depende de la Capa 1 del documento semántico |
| **DESIGN-03** no se puede localizar nada | ✅ verificado | **`locate`**: apunta la cámara y selecciona. Para aberturas encuadra de frente desde afuera del muro |

---

## Lo que NO está corregido

### BUG-06 — editar una puerta fusiona a su vecina

No lo toqué porque reproducirlo exige mutar geometría real y comparar antes y
después, y el ciclo de prueba sobre un modelo de 85 MB es lento. La corrección de
BUG-05 **puede** haberlo movido (la detección de `ASSEMBLY` ahora trabaja sobre
datos consistentes), pero **no lo doy por resuelto sin reproducirlo**.

Para atacarlo: `tools/smoke_bugs.py --full` ya arma un modelo desechable y
ejercita las rutas de mutación; falta añadirle el caso exacto de tu repro (las
dos puertas de balcón adyacentes, `80482:9.41,27.62,4.77` y
`80482:10.27,27.44,4.77`).

### DESIGN-02 — creación de geometría

Diferido a propósito, siguiendo tu propio documento: la Capa 3 sin Capa 1
degenera en pedirle coordenadas al usuario.

---

## Nuevo en v0.3.0

- **`locate(pid | opening_id)`** — mueve la cámara y selecciona. Es la mejora de
  usabilidad que pedía DESIGN-03: convierte "adivina y verifica" en "yo te lo
  señalo". Flujo sugerido para el agente: `find` → `locate` → *"¿es este?"* →
  editar.
- **`delete_project` / `delete_client`** — nunca tocan el `.skp` ni sus versiones.
- **`list_openings` con `summary`, `kind`, `limit`, `offset`, `include_furniture`.**
- **Anomalías en todo:** losas y aberturas reportan `anomalies` en vez de
  desaparecer del inventario. Es el principio que dejó BUG-04: *nada se
  esconde en silencio.*
- **`tools/smoke_bugs.py`** — suite de regresión por número de bug. El modo
  rápido corre en ~40 s sin mutar nada; `--full` ejercita mutación y rollback.

## Lo que confirmó el reporte y no cambió

Las cosas que marcaste como "funcionó bien" siguen igual: `health_check`,
`resize_opening` en aberturas aisladas, `set_slab_thickness` con `datum='top'`,
`restore_version`, parametrización SQL, Unicode en briefs, y el estilo de los
mensajes de error accionables. Ese estilo se extendió a todos los errores
nuevos: qué pasó, por qué, y qué hacer.
