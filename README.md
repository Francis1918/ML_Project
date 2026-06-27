# ML_Project — Fase 2, Avance 1

Plataforma académica de visualización y análisis de velas japonesas con Smart Money Concepts (SMC).
**No genera señales financieras reales. Uso exclusivamente académico.**

## Cómo iniciar

```bash
./start.sh
```

Abre automáticamente el navegador en `http://localhost:3000`.

---

## Qué está implementado (Avance 1 — 29/06)

### Motor de datos
- Lectura de CSV 1m y construcción automática de **8 temporalidades**: 1m, 5m, 15m, 1h, 2h, 4h, D, W
- Agregación OHLCV estricta: Open=primera, High=máx, Low=mín, Close=última, Volume=suma
- Semanas calculadas como ISO (lunes como inicio de semana)

### Replay sin look-ahead bias
- Parámetro `replay_index` en ambas APIs: `/api/candles` y `/api/overlays`
- Ningún cálculo usa velas con `index > max_visible_index`
- Controles de UI: « ‹ ▶/⏸ › » + teclado (← → Space Esc)
- Pivots solo confirmados cuando `max_visible_index >= pivot_index + k`

### Liquidez (`Market::Indicators::Liquidity`)
- Detecta **BSL** (Buy Side Liquidity), **SSL** (Sell Side Liquidity)
- Detecta **EQH** / **EQL** con tolerancia `ATR × 0.10`
- Máquina de estados: `DETECTED → SWEPT → ACCEPTANCE → RESOLVED(RUN)` o `RECLAIMED → RESOLVED(GRAB/SWEEP)`
- Clasificación final: **SWEEP** / **GRAB** / **RUN**
- Volume weights por evento (vol_ratio = vol_candle / rolling_avg_14)
- Distinción internal vs external por precio

### Estructura SMC (`Market::Indicators::SMC_Structures`)
- Swing Points con `k=3` configurable
- Etiquetas **HH / HL / LH / LL** en pivots
- **BOS** (Break of Structure) solo confirmado por cierre, nunca por mecha
- **CHoCH** solo si invalida un major high/low externo
- **FVG** bullish/bearish con desvanecimiento progresivo (`fade_rate=0.03`)
- **HIGH REACTION FVG**: marcado cuando nace en la vela de un Sweep/Grab
- **Fibonacci automático** anclado al último swing externo (0.236, 0.382, 0.5, 0.618, 0.786)
- Distinción estructura interna (minor) vs externa (major)

### Contexto de mercado (`Market::Indicators::MarketRegime`)
- 8 estados: `UNKNOWN` `ZONA_INTERNA` `LIQUIDEZ_INTERNA` `LIQUIDEZ_EXTERNA` `ZM_MANIPULATION` `TRANSITION` `TR_BULLISH` `TR_BEARISH`
- BOS/CHoCH/Sweep/Grab/Run son *transiciones*, no estados
- Liquidez externa tiene prioridad sobre interna
- Produce `reason`, `previous_state` y `confidence_score` auditables
- Sin look-ahead: respeta `max_visible_index`

### Overlays visuales (`Market::Overlays::*`)
- Formas JSON: `line`, `rectangle`, `label`, `marker`, `fib_line`
- BSL/SSL/EQH/EQL → líneas horizontales con colores por rol
- SWEEP ^/v, LQ GRAB, LQ RUN → marcadores
- BOS/CHoCH → líneas + etiquetas (sólido=externo, discontinuo=interno)
- FVG → rectángulos semitransparentes con fade temporal
- Pivots → etiquetas HH/HL/LH/LL
- Fibonacci → líneas punteadas grises con ratio
- **Proyección HTF sobre LTF**: niveles activos de 1h/4h/D visibles al ver 5m/15m

### Frontend
- Barra con **8 botones de TF**: 1m 5m 15m 1h 2h 4h D W
- Controles de Replay integrados en toolbar
- Badge de régimen en canvas (color por estado)
- Statusbar: `TF | modo | barras | offset | RÉGIMEN (score)`
- Zoom Ctrl+scroll (anclado al cursor), scroll horizontal, zoom vertical (Shift+scroll)

### APIs
```
GET /api/candles?tf=15m[&replay_index=N]
GET /api/overlays?tf=15m[&replay_index=N][&start=0][&end=200]
GET /api/info
```

---

## Limitaciones conocidas (quedan para 13/07)

| Pendiente | Motivo |
|---|---|
| Strategy Builder | Requiere más análisis de confluencias |
| Order Blocks | Opcional para avance 1 según spec |
| Trendline liquidity (dinámica) | Requiere detección de pendientes |
| Volume weights 1m/5m/15m reales por sub-vela HTF | Actualmente usa vol del TF actual |
| Perfil de Volumen | Fuera de scope avance 1 |
| Anchored VWAP | Fuera de scope avance 1 |
| Dashboard de backtesting | Fuera de scope avance 1 |
| sml.pm / entrenamiento ML | Etapa posterior al avance 1 |

---

## Arquitectura

```
backend/
  app.pl                          → Servidor Mojolicious, caché por TF, endpoints
  data/2026_03.csv                → Datos OHLCV 1m
  Market/
    MarketData.pm                 → Carga CSV, construye 8 TFs, anchors
    IndicatorManager.pm           → Registro plug-in de indicadores
    Indicators/
      ATR.pm                      → Wilder RMA (período 14)
      Liquidity.pm                → BSL/SSL/EQH/EQL + máquina de estados
      SMC_Structures.pm           → Pivots, BOS/CHoCH, FVG, Fibonacci
      MarketRegime.pm             → Máquina de contexto de mercado
    Overlays/
      Liquidity.pm                → Shapes JSON para niveles/eventos
      SMC_Structures.pm           → Shapes JSON para estructura/FVG/Fibonacci

frontend/
  index.html / styles.css         → UI + replay controls
  scales.js                       → Coordenadas data↔pantalla
  price_panel.js                  → Renderizado de velas y eje de tiempo
  atr_panel.js                    → Panel ATR
  chart_engine.js                 → Motor principal, overlays, badge de régimen
  app.js                          → Orquestador, replay, fetch de APIs
```

---

## Defensa académica

> El sistema no es un modelo predictivo. Implementa una capa analítica determinista sobre datos OHLCV que detecta eventos de estructura e ineficiencias de precio con reglas auditables. La máquina de estados produce contexto estructural por vela (no señales de compra/venta), preparando los eventos como dataset etiquetado para una etapa ML posterior.
