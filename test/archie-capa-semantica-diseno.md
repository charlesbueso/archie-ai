# Archie — Capa semántica y tools avanzados

**Documento de diseño · 10 agosto 2026**
**Autor:** sesión de exploración Carlos + Claude sobre `CASA CUMBRES DE JUAREZ_original.skp`
**Propósito:** definir la arquitectura y el orden de construcción para que Archie entienda peticiones en lenguaje natural ("el balcón del segundo piso de atrás") y pueda crear geometría ("una alberca en el jardín"), antes de sentarse a implementar con Claude Code.

---

## 1. Diagnóstico

El problema no es el número de tools. Es que **entre la geometría cruda y el lenguaje del arquitecto no hay nada**.

Hoy el agente recibe pids, coordenadas y bounding boxes. El usuario habla de plantas, fachadas, cuartos, jardín, frente y fondo. Cada tool nuevo construido sobre la base actual hereda la misma ceguera.

### Evidencia: el modelo de niveles no corresponde a pisos humanos

`get_model_info` sobre el modelo de prueba devuelve siete "storeys":

| Nivel | FFL (m) | Realidad |
|---|---|---|
| N0 | 0.00 | Planta baja |
| N1 | 0.32 | Planta baja (desnivel interior) |
| N2 | 0.62 | Planta baja (desnivel interior) |
| N3 | 3.57 | Primer piso |
| N4 | 6.487 | Azotea / segundo nivel |
| N5 | 6.621 | Azotea (espesor de losa) |
| N6 | 8.407 | Pretil / casa de máquinas |

Son **niveles z detectados**, no plantas. Si el usuario dice "segundo piso" y el agente busca N2, apunta a la planta baja con total confianza.

**Implicación:** se necesita agrupación de FFLs cercanos (tolerancia ~1.5m) en plantas humanas, con nombres convencionales (PB, N1, N2 / Planta Baja, Primer Piso).

### Evidencia: geometría no arquitectónica contamina la detección

`list_openings` con umbrales bajos clasifica como `WINDOW` piezas de un candelabro West Elm de 2×2 cm. El detector no tiene noción de "¿este contenedor es un muro?".

### Evidencia: el modelo tiene basura que nadie ha visto

Group#20 (pid 2481304) y Group#153 (pid 36083) tienen **footprint idéntico (15.97 × 22.88), z idéntico (-0.25 a 0.0) y área idéntica (365.4 m²)**. Son losas duplicadas encimadas. Nadie lo sabía hasta esta sesión.

Esto es una pista de producto: **el modelo del arquitecto contiene información que él mismo no tiene consciente.** Ahí está el efecto "wow".

---

## 2. Arquitectura propuesta: tres capas

```
┌─────────────────────────────────────────────┐
│  CAPA 3 — Acción                            │
│  crear, modificar, batch edits              │
├─────────────────────────────────────────────┤
│  CAPA 2 — Resolución                        │
│  lenguaje natural → pids concretos          │
│  confirmación visual (zoom_to)              │
├─────────────────────────────────────────────┤
│  CAPA 1 — Modelo semántico  ← LO QUE FALTA  │
│  plantas, fachadas, espacios, envolvente,   │
│  sitio, clasificación de elementos          │
├─────────────────────────────────────────────┤
│  CAPA 0 — Geometría cruda (existe hoy)      │
│  pids, bbox, vértices, entidades            │
└─────────────────────────────────────────────┘
```

**Regla de oro:** no construir Capa 3 antes de Capa 1. Todo tool de creación que no sepa dónde está el jardín va a pedirle coordenadas al usuario, y en ese momento Archie deja de ser mágico y se vuelve una calculadora.

---

## 3. Capa 1 — Modelo semántico

Es el trabajo de fondo. Todo lo demás depende de esto.

### 3.1 Plantas humanas (`storeys` → `levels`)

Agrupar FFLs detectados dentro de una tolerancia configurable (default ~1.5m) en plantas.

```
levels: [
  { id: "PB",  name: "Planta Baja",   ffl: 0.0,   ffl_variants: [0.0, 0.32, 0.62],
    height: 3.57, area_m2: 219.7 },
  { id: "N1",  name: "Primer Piso",   ffl: 3.57,  ffl_variants: [3.57],
    height: 2.82, area_m2: 216.5 },
  { id: "AZ",  name: "Azotea",        ffl: 6.487, ffl_variants: [6.487, 6.621],
    height: 1.79, area_m2: 82.6 }
]
```

Cada elemento (losa, abertura, muro) debe reportar a qué `level` pertenece, no solo su z absoluta.

**Ambigüedad a resolver con el usuario:** en México "segundo piso" puede significar N1 (el segundo nivel contando PB) o N2. Conviene que Archie confirme la primera vez y guarde la convención en el brief del proyecto.

### 3.2 Orientación del edificio

No es derivable de la geometría sola. Se establece una vez y se persiste.

```
create_or_update_orientation(project, front_axis: "-Y" | "+Y" | "-X" | "+X",
                             north_azimuth: <grados, opcional>)
```

Deriva automáticamente: `frente / atrás / izquierda / derecha`, y si hay azimut norte, también `norte / sur / oriente / poniente` (los arquitectos mexicanos usan orientación solar constantemente para asoleamiento).

**Heurística para proponer un default:** la fachada que contiene la puerta de acceso principal (la puerta más ancha a nivel de PB que da al exterior) es probablemente el frente. Proponerlo, no imponerlo.

### 3.3 Envolvente y sitio

- **Huella construida** (`building_footprint`): unión de las losas de PB que pertenecen al edificio.
- **Sitio / terreno** (`site`): losas horizontales grandes al nivel del suelo o por debajo, que se extienden más allá de la huella. En el modelo de prueba: Group#1 (13.99 × 43.33 m) y Group#20/Group#153 (15.97 × 22.88 m, duplicados).
- **Áreas exteriores** (`outdoor_areas`): sitio menos huella, segmentado por lado según la orientación → `jardín trasero`, `patio lateral`, `acceso frontal`.

Esto es lo que permite que "en el jardín trasero" signifique algo.

### 3.4 Clasificación de elementos

Reemplazar la clasificación actual (frágil, inestable entre llamadas — ver BUG-05) por una que use contexto:

| Tipo | Criterio |
|---|---|
| `FLOOR_SLAB` | Losa horizontal en un FFL, cubierta por otra losa arriba |
| `ROOF_SLAB` | Losa horizontal sin losa arriba, sobre área cerrada |
| `BALCONY` | Losa a nivel de piso, proyectada más allá de la huella del nivel superior, con abertura tipo puerta que da hacia ella |
| `TERRACE` | Como balcón pero en PB o azotea, área mayor |
| `EXTERIOR_WALL` | Muro en el perímetro de la envolvente |
| `INTERIOR_WALL` | Muro dentro de la envolvente |
| `FURNITURE` | Componente que no participa de la envolvente — **excluir del análisis de aberturas** |

**Nota crítica:** la clasificación debe ser determinista y estable. Hoy una abertura cambia de `DOOR` a `ASSEMBLY` sin que su geometría cambie (BUG-05). Sin estabilidad, la Capa 2 es imposible.

### 3.5 Espacios (cuartos) — fase posterior

Detección de espacios cerrados (space boundary detection) es el problema más caro de la lista. **Antes de invertir ahí, hacer descubrimiento** (ver §6): los modelos reales de arquitectos suelen traer capas/tags nombradas ("RECAMARA 1", "BAÑO"). Si es así, leer nombres es 10× más barato que inferir geometría.

---

## 4. Capa 2 — Resolución y confirmación

### 4.1 `describe_building()` — el tool más importante

Devuelve un resumen semántico compacto del modelo entero. Es lo primero que el agente llama en cada sesión, y sustituye al `get_model_info` verboso actual.

```
{
  levels: [...],
  orientation: { front: "-Y", north_azimuth: 15 },
  built_area_m2: 412,
  site_area_m2: 606,
  counts: { doors: 12, windows: 26, balconies: 2, terraces: 1 },
  outdoor_areas: [ { name: "jardín trasero", area_m2: 187, side: "back" } ],
  anomalies: [ ... ]   // ver §5.1
}
```

Debe caber cómodamente en contexto. Compárese con la llamada actual de `list_openings` sin filtros: ~180 objetos JSON verbosos.

### 4.2 `find(description)` — resolución en lenguaje natural

```
find("el balcón del segundo piso de atrás")
→ {
    matches: [
      { pid: 2481680, confidence: 0.91, kind: "BALCONY", level: "N1",
        side: "back", area_m2: 12.4,
        why: "losa a 3.57m, proyecta 1.8m fuera de la huella del nivel superior,
              lado -Y (atrás), con puerta doble dando hacia ella" }
    ],
    ambiguous: false
  }
```

**Requisitos de diseño:**
- Devolver **candidatos rankeados con explicación**, nunca una respuesta única silenciosa. El agente debe poder decirle al usuario *por qué* cree que es ese.
- Marcar `ambiguous: true` cuando hay empate, para que el agente pregunte en vez de adivinar.
- Soportar español mexicano con y sin acentos (ver BUG-11), y vocabulario local: *losa, pretil, cochera, patio de servicio, sala-comedor, medio baño, vestidor, cubo de luz, faldón*.

### 4.3 `zoom_to(pid)` / `highlight(pid)` — el mayor salto de usabilidad

Mueve la cámara de SketchUp al elemento y lo resalta.

**Justificación empírica:** en esta sesión, encontrar una sola ventana tomó **seis intentos** con un usuario no experto en SketchUp, orbitando y haciendo clic a ciegas. Los grupos no tienen nombres, así que el buscador del Outliner no sirve. `get_selection` permite verificar *después* del clic, pero no guiar *antes*.

Con `zoom_to`, el flujo pasa de "adivina y verifica" a **"yo te lo señalo, confirma"**. Es probablemente la mejora individual más grande disponible, y es barata de implementar.

**Ciclo de confirmación propuesto:**
1. Usuario: *"haz más grande el balcón de atrás"*
2. Agente: `find()` → candidato con 0.91 de confianza
3. Agente: `zoom_to(pid)` → *"Me refiero a este. ¿Correcto?"*
4. Usuario confirma
5. Agente ejecuta

Esto también resuelve el riesgo de que el agente edite el elemento equivocado con confianza.

---

## 5. Capa 3 — Acción

### 5.1 Auditoría de modelo (`audit_model`) — empezar por aquí

**Solo lectura, cero riesgo, valor inmediato, y demuestra comprensión.**

Detecta y reporta:
- Geometría duplicada / encimada (ejemplo real: Group#20 y Group#153, losas idénticas)
- Losas con espesor inconsistente entre sí
- Aberturas con antepecho negativo (bajo el nivel de piso — hay varias en el modelo de prueba)
- Componentes huérfanos fuera de la envolvente
- Losas degeneradas o de volumen nulo
- Muros que no llegan a la losa superior
- Conteo de componentes duplicados que podrían ser instancias

**Por qué primero:** con 20 bugs abiertos en el motor de mutación, los tools de lectura son los únicos seguros de mostrar a usuarios beta. Y honestamente son más impresionantes: decirle a un arquitecto algo cierto sobre su propio modelo que él no sabía genera más confianza que dibujarle una caja.

### 5.2 Primitivas de creación

Parametrizadas, no geometría libre. Todas con snapshot previo real (requiere BUG-01 resuelto) y `dry_run` que **sí** simule el resultado (BUG-20).

```
create_slab(level, polygon | rect, thickness, datum)
create_wall(level, start_xy, end_xy, height, thickness)
create_opening(wall_pid, kind, width, height, sill, position)
create_pool(area, length, width, depth, coping_width, position)
create_stairs(...)   // fase posterior, geométricamente complejo
```

**Sobre la alberca:** geométricamente es trivial (excavación rectangular + brocal). Lo difícil es *dónde*, y eso lo resuelve la Capa 1 (`outdoor_areas`). Una firma realista:

```
create_pool(area: "jardín trasero", length: 8, width: 4, depth: 1.5,
            setback_from_house: 3, align: "parallel_to_back_facade")
```

Sin Capa 1, esta firma degenera en `create_pool(x, y, z, ...)` y Archie deja de ser mágico.

### 5.3 Edición por lote — el caso de uso que vende el producto

```
resize_openings(filter: { kind: "WINDOW", level: "N1", side: "west" },
                height_delta: +0.20)
```

*"Sube 20cm todas las ventanas del poniente del primer piso."* Es exactamente el trabajo tedioso que un arquitecto haría a mano en 40 minutos. Depende de que la clasificación sea estable (BUG-05) y de que las aberturas adyacentes no se fusionen al editarlas (BUG-06).

---

## 6. Protocolo de descubrimiento (antes de escribir código)

El riesgo mayor es construir la Capa 1 sobre suposiciones equivocadas de cómo modelan los arquitectos reales.

### 6.1 Sondeo de modelos reales

Pedir a Omar y a los 3 beta **3–5 archivos `.skp` reales cada uno** (proyectos entregados, no ejercicios) y correr un script de inventario que responda:

| Pregunta | Por qué importa |
|---|---|
| ¿Usan capas/tags nombradas? ¿Con qué convención? | Si sí, la detección de espacios es leer nombres en vez de inferir geometría |
| ¿Nombran los grupos y componentes? | Determina si `find()` puede apoyarse en texto |
| ¿Usan el sistema de Classifications de SketchUp (IFC)? | Si sí, hay tipos gratis |
| ¿Los muros son sólidos, o caras sueltas? | Define la viabilidad del análisis de envolvente |
| ¿Hay geometría de sitio/terreno? ¿Cómo? | Necesario para áreas exteriores |
| ¿Qué tan anidados están los grupos? | Este modelo tiene hasta 6 niveles; afecta todo recorrido |
| ¿Modelan por nivel, o todo mezclado? | Determina si `levels` es confiable |
| ¿Traen mobiliario de 3D Warehouse? | Es la fuente del ruido en detección de aberturas |

Un solo script, corriendo sobre ~15 modelos reales, contesta esto en una tarde y **decide la arquitectura de la Capa 1**.

### 6.2 Corpus de peticiones ("golden set")

Pedir a cada uno de los 4 arquitectos que escriban **20–30 frases** de cosas que le pedirían a Archie, en su español natural, sin pensar en si es posible.

Esto sirve para tres cosas:
1. Define el vocabulario real que `find()` debe entender (no el que nosotros imaginamos)
2. Se convierte en el **eval set** para probar cada iteración
3. Revela qué quieren de verdad — probablemente no sea lo que estamos construyendo

**Instrucción sugerida para ellos:** *"Imagina que tu modelo te entiende hablado. Escribe 25 cosas que le dirías en un día normal de trabajo. No te limites a lo que crees que se puede."*

### 6.3 Sesiones de observación

Grabar a Omar trabajando 30 minutos en SketchUp sin Archie. Anotar dónde pierde tiempo. Los tools deben atacar eso, no lo que sea elegante de programar.

---

## 7. Orden de construcción propuesto

| Fase | Contenido | Justificación |
|---|---|---|
| **0** | Arreglar BUG-01, 02, 03 (snapshots, rollback, validación) | Sin red de seguridad confiable, nada más es seguro de construir |
| **1** | Descubrimiento (§6): sondeo de modelos + golden set | Define la arquitectura de la Capa 1 con datos, no suposiciones |
| **2** | `zoom_to` / `highlight` | Barato, y arregla el cuello de botella real del flujo actual |
| **3** | Capa 1: levels, orientación, envolvente, sitio, clasificación estable | Fundamento de todo lo demás |
| **4** | `describe_building` + `audit_model` | Solo lectura, cero riesgo, máximo efecto "wow" para los beta |
| **5** | `find(description)` con ciclo de confirmación visual | Convierte a Archie en conversacional |
| **6** | Edición por lote sobre elementos ya resueltos | El caso de uso que justifica pagar por el producto |
| **7** | Primitivas de creación (incluida la alberca) | Lo más vistoso, pero lo que más depende de todo lo anterior |

---

## 8. Nota sobre la demo a los beta

Vale la pena separar dos cosas que se confunden fácil:

**Lo vistoso** — poner una alberca en el jardín. Impresiona 30 segundos. Si sale mal (y con el motor actual, saldrá mal), destruye la confianza de golpe.

**Lo valioso** — que Archie describa correctamente el modelo del arquitecto, encuentre lo que él le pide en su propio lenguaje, y le señale tres problemas de su modelo que no sabía que tenía. Eso no se agota, y no puede corromper nada.

Para tres arquitectos beta que van a decidir si esto vale su tiempo, la segunda ruta es más segura y probablemente más impresionante. La creación de geometría se agrega después, cuando el fundamento aguante.

---

## 9. Preguntas abiertas

- ¿"Segundo piso" en México cuenta desde PB o desde el primer nivel? Confirmar con los cuatro y fijar convención por proyecto.
- ¿Conviene que Archie escriba nombres a los grupos del modelo (`"BALCON_N1_POSTERIOR"`) para que el usuario también los vea en el Outliner? Sería un puente entre las dos formas de trabajar, pero modifica el modelo del cliente.
- ¿Qué tanto del análisis debe cachearse? Recalcular la Capa 1 en cada llamada sobre un modelo de 672 contenedores puede ser lento.
- ¿Multi-modelo? Un proyecto real tiene arquitectónico, estructural, instalaciones. Fuera de alcance por ahora, pero condiciona el esquema de datos.
