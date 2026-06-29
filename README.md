# ML_Project - Plataforma de Trading SMC/Liquidity

Proyecto académico de visualización y análisis de velas OHLCV para construir una plataforma de trading con múltiples temporalidades, Replay, overlays Smart Money Concepts y motor de liquidez.

El foco del avance actual es tener una base funcional para el primer corte del 29/06: temporalidades, Replay, ATR, SMC, FVG con desvanecimiento progresivo, módulo de liquidez y controles visuales de overlays.

## Estado actual del avance

### Implementado

- Carga de datos OHLCV desde CSV base de 1 minuto.
- Construcción de temporalidades: `1m`, `5m`, `15m`, `1h`, `2h`, `4h`, `D`, `W`.
- API Mojolicious para entregar velas, ATR y overlays al frontend.
- Frontend HTML/Canvas para visualización de velas.
- Zoom horizontal, zoom vertical, drag horizontal y modo manual/auto.
- Crosshair sincronizado entre panel de precio y panel ATR.
- Replay sin solicitar velas posteriores al índice activo desde la API.
- ATR en panel inferior.
- SMC Structures:
  - pivots `HH`, `HL`, `LH`, `LL`,
  - `BOS`,
  - `CHoCH`,
  - `FVG`,
  - FVG de alta reacción asociado a eventos de liquidez.
- Liquidity:
  - `BSL`,
  - `SSL`,
  - `EQH`,
  - `EQL`,
  - `SWEEP`,
  - `GRAB`,
  - `RUN`,
  - máquina de estados básica: `DETECTED`, `SWEPT`, `ACCEPTANCE`, `RECLAIMED`, `RESOLVED`.
- Market Regime visual como badge.
- Menú de indicadores para activar/desactivar capas visuales sin recalcular indicadores.
- Proyección de liquidez externa HTF sobre temporalidades menores.
- Pesado de volumen multi-temporal para eventos y niveles de liquidez.
- Endpoint normalizado de eventos SMC por rango visible: `/api/indicators/smc/events`.
- MSS, pivots strong/weak, Premium/Discount, Previous High/Low y estados `active`, `mitigated`, `invalidated` para FVG.
- Configuración central del motor SMC en `backend/Market/SMCConfig.pm`.

Documentación técnica ampliada: [`docs/SMC_INDICATOR.md`](docs/SMC_INDICATOR.md).

### Parcial o pendiente para siguientes entregas

- DIY Custom Strategy Builder.
- Perfil de Volumen avanzado.
- Anchored VWAP multipivote.
- Controles de Replay más completos a nivel de UX.
- Validación estadística formal de señales.
- Persistencia o exportación de eventos para análisis posterior.

## Arquitectura general

```text
ML_Project/
├── backend/
│   ├── app.pl
│   ├── data/
│   │   └── 2026_03.csv
│   └── Market/
│       ├── MarketData.pm
│       ├── IndicatorManager.pm
│       ├── SMCConfig.pm
│       ├── Indicators/
│       │   ├── ATR.pm
│       │   ├── Liquidity.pm
│       │   ├── MarketRegime.pm
│       │   └── SMC_Structures.pm
│       └── Overlays/
│           ├── Liquidity.pm
│           └── SMC_Structures.pm
├── frontend/
│   ├── index.html
│   ├── app.js
│   ├── chart_engine.js
│   ├── price_panel.js
│   ├── atr_panel.js
│   ├── scales.js
│   └── styles.css
├── cpanfile
├── instalar_dependencias.sh
└── start.sh
```

## Backend

### `MarketData.pm`

Responsable de almacenar velas OHLCV y construir temporalidades derivadas desde el CSV de 1 minuto.

Regla de agregación OHLCV:

- `open`: apertura de la primera vela del bloque.
- `high`: máximo del bloque.
- `low`: mínimo del bloque.
- `close`: cierre de la última vela del bloque.
- `volume`: suma del volumen del bloque.

### `Indicators/ATR.pm`

Calcula ATR incremental para acompañar cada temporalidad.

### `Indicators/Liquidity.pm`

Motor analítico de liquidez. Detecta niveles y eventos.

Niveles:

- `BSL`: Buy Side Liquidity.
- `SSL`: Sell Side Liquidity.
- `EQH`: Equal Highs.
- `EQL`: Equal Lows.

Eventos:

- `SWEEP`: barrido con retorno.
- `GRAB`: rechazo rápido en máximo 3 velas.
- `RUN`: aceptación con cierres consecutivos fuera del nivel.

Cada nivel/evento conserva `volume_weights`. En la versión actual incluye datos legacy y pesado multi-temporal:

```json
{
  "vol_at": 1200,
  "vol_avg": 900,
  "vol_ratio": 1.33,
  "m1":  { "volume": 1200, "avg": 900, "ratio": 1.33, "candles": 1, "estimated": 0 },
  "m5":  { "volume": 5400, "avg": 4800, "ratio": 1.12, "candles": 1, "estimated": 1 },
  "m15": { "volume": 15000, "avg": 13000, "ratio": 1.15, "candles": 1, "estimated": 1 },
  "score": 0.40,
  "estimated": 1
}
```

`estimated = 1` significa que para esa fuente se usó una vela contenedora o aproximada porque la ventana activa no contenía sub-velas exactas de esa granularidad.

### `Indicators/SMC_Structures.pm`

Calcula estructuras SMC:

- pivots `HH`, `HL`, `LH`, `LL`,
- pivots `strong_high`, `weak_high`, `strong_low`, `weak_low`,
- `BOS`,
- `CHoCH`,
- `MSS`,
- FVG bullish/bearish,
- Fibonacci y Premium/Discount,
- Previous High/Low proyectado desde velas cerradas,
- FVG de alta reacción cuando aparece asociado a barridos o grabs de liquidez.

### `Indicators/MarketRegime.pm`

Clasifica el régimen visual del mercado usando liquidez, estructura y contexto reciente.

### `Overlays/*.pm`

No recalculan indicadores. Transforman los resultados analíticos en shapes consumibles por el frontend.

Ejemplo de shape:

```json
{
  "source_type": "liquidity",
  "kind": "line",
  "timeframe": "1h",
  "x1_index": 0,
  "x2_index": 500,
  "y1_price": 5320.25,
  "color_role": "bsl",
  "line_style": "solid",
  "opacity": 0.48,
  "htf_source": 1,
  "internal_or_external": "external"
}
```

## Liquidez externa HTF

La liquidez HTF se proyecta en temporalidades menores desde `backend/app.pl`.

Mapa de fuentes HTF:

```text
1m  -> 5m, 15m, 1h, 4h, D, W
5m  -> 15m, 1h, 4h, D, W
15m -> 1h, 4h, D, W
1h  -> 2h, 4h, D, W
2h  -> 4h, D, W
4h  -> D, W
D   -> W
W   -> sin HTF superior
```

La API normal `/api/overlays` ya agrega estos niveles en el flujo rápido, no únicamente en modo debug/full.

Para evitar fuga de futuro en Replay, solo se proyectan niveles de velas HTF cerradas según el tiempo visible actual.

## Frontend

### `chart_engine.js`

Motor de render Canvas.

Responsabilidades principales:

- render de velas,
- render ATR,
- escalas de precio y tiempo,
- zoom y drag,
- crosshair,
- render de overlays,
- filtro visual por capa.

El filtro de capas es solo visual. Los datos del backend siguen llegando completos.

### Menú de indicadores

La barra superior permite activar o desactivar capas:

SMC:

- Motor SMC,
- Internal Structure,
- Swing Structure,
- Strong / Weak,
- HH,
- HL,
- LH,
- LL,
- CHoCH,
- BOS,
- MSS,
- FVG fade,
- Fibonacci Auto,
- Premium / Discount,
- Previous High / Low,
- Market Regime.

Liquidez:

- Módulo completo,
- Liquidez HTF,
- BSL,
- SSL,
- EQH,
- EQL,
- Liquidity Grab,
- Sweep,
- Run.

## API principal

### `/api/info`

Devuelve metadatos de temporalidades, configuración SMC y estado de cachés.

### `/api/candles`

Parámetros principales:

- `tf`: temporalidad.
- `start`: índice absoluto inicial.
- `end`: índice absoluto final.
- `limit`: tamaño de ventana.
- `replay_index`: corte de Replay.
- `all`: entrega todo el histórico de la temporalidad.

### `/api/overlays`

Devuelve overlays SMC, liquidez y régimen de mercado.

Parámetros principales:

- `tf`
- `start`
- `end`
- `limit`
- `replay_index`
- `absolute`
- `debug`
- `full`

La ruta normal calcula overlays ventaneados con lookback y agrega liquidez externa HTF.

### `/api/indicators/smc/events`

Devuelve eventos SMC normalizados por rango visible.

Parámetros principales:

- `tf` o `timeframe`
- `start`
- `end`
- `from`
- `to`
- `limit`
- `replay_index`
- `symbol`

Incluye eventos anclados por vela como swings, `HH/HL/LH/LL`, BOS, CHoCH, MSS, FVG, OB, Supply/Demand, Support/Resistance, Trendlines/Channels, Fibonacci, Daily body/wick, Premium/Discount, HTF liquidity y Previous High/Low.

El limite por defecto de eventos esta centralizado en `backend/Market/SMCConfig.pm` (`maxEventsPerRequest`) y se aplica despues de filtrar por rango visible.

## Ejecución local

Instalar dependencias Perl indicadas en `cpanfile` o usando el script del proyecto.

```bash
./instalar_dependencias.sh
./start.sh
```

Luego abrir el frontend en el puerto configurado por `app.pl`.

## Criterios usados para el primer avance

Para el avance del 29/06, el proyecto debe demostrar:

- soporte base de múltiples temporalidades,
- Replay sin filtración directa de velas futuras desde la API,
- arquitectura base de overlays gráficos,
- avance del motor SMC con etiquetas ubicadas en el tiempo,
- FVG con desvanecimiento progresivo,
- módulo de liquidez implementado,
- separación visual de capas desde la interfaz.
