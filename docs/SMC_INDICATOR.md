# SMC / Price Action Suite

Este documento describe la implementacion incremental del indicador SMC / Price Action Suite del proyecto.

## Que Detecta

- Liquidez: BSL, SSL, EQH, EQL, sweeps, grabs, runs y niveles HTF proyectados sobre temporalidades menores.
- Estructura: swing highs/lows confirmados, pivots strong/weak, BOS, CHoCH, MSS, internal BOS e internal CHoCH.
- Fair Value Gaps: bullish y bearish FVG con estado `active`, `mitigated` o `invalidated`.
- Zonas: Order Blocks, Supply y Demand reutilizando `Strategy_Builder.pm`.
- Premium / Discount: rango estructural, premium, equilibrium 50% y discount.
- Previous High/Low: PDH, PDL, PWH, PWL y, cuando el historico lo permite, PMH/PML.
- Contexto: maquina de estados `UNKNOWN`, `ZONA_INTERNA`, `LIQUIDEZ_INTERNA`, `LIQUIDEZ_EXTERNA`, `ZM_MANIPULATION`, `TRANSITION`, `TR_BULLISH`, `TR_BEARISH`.

## Arquitectura

- `Market/SMCConfig.pm` centraliza parametros del indicador: lookback, tolerancias, limites, HTF y flags funcionales.
- `Market/Indicators/Liquidity.pm` calcula niveles y eventos de liquidez.
- `Market/Indicators/SMC_Structures.pm` calcula pivots, pivots strong/weak, BOS, CHoCH, MSS, FVG, Fibonacci y Premium/Discount.
- `Market/Indicators/Strategy_Builder.pm` mantiene SuperTrend, HalfTrend, Range Filter, Supply/Demand y Order Blocks. Los OB ahora se validan con desplazamiento fuerte y estructura cercana.
- `Market/Indicators/MarketRegime.pm` consume eventos, no los duplica, y produce el estado contextual.
- `Market/Overlays/*.pm` transforma datos analiticos en shapes; no recalcula logica de mercado.
- `backend/app.pl` expone velas, overlays, HTF liquidity, Previous High/Low y el endpoint de eventos normalizados.

## Endpoint de Eventos

```text
GET /api/indicators/smc/events?symbol=DEFAULT&timeframe=1m&from=2026-06-29T10:00:00&to=2026-06-29T12:00:00
```

Tambien acepta el patron existente:

```text
GET /api/indicators/smc/events?tf=1m&start=1200&end=1700
```

Cada evento incluye `id`, `type`, `symbol`, `timeframe`, `source_timeframe` si aplica, `start_time`, `end_time`, `confirmation_time`, `price`, `top`, `bottom`, `direction`, `strength`, `status` y `metadata`.

El endpoint devuelve eventos que nacen dentro del rango, siguen activos dentro del rango o tienen una zona proyectada que intersecta el rango visible.

Eventos agregados o normalizados por el flujo SMC:

- `SWING_HIGH`, `SWING_LOW`, con `metadata.strength_class` (`strong_high`, `weak_high`, `strong_low`, `weak_low`).
- `HH`, `HL`, `LH`, `LL` como alias estructurales anclados al mismo swing confirmado.
- `BOS`, `CHOCH`, `MSS`, con `confirmation_time`.
- `FVG`, `ORDER_BLOCK`, `SUPPLY_ZONE`, `DEMAND_ZONE`, con estado historico.
- `INSIDE_BULLISH_OB`, `INSIDE_BEARISH_OB` para entradas de precio en Order Blocks.
- `SUPPORT_LEVEL`, `RESISTANCE_LEVEL`, `NEAR_SUPPORT`, `NEAR_RESISTANCE`, `BREAK_SUPPORT`, `BREAK_RESISTANCE`.
- `TRENDLINE_SUPPORT`, `TRENDLINE_RESISTANCE`, `ABOVE_TRENDLINE`, `BELOW_TRENDLINE`, `CHANNEL`, `INSIDE_CHANNEL`, `BREAKOUT_CHANNEL_UP`, `BREAKOUT_CHANNEL_DOWN`.
- `FIB_LEVEL`, `NEAR_FIB_LEVEL`, con relacion actual `above`, `below` o `near` en metadata.
- `NEAR_EQH`, `ABOVE_EQH`, `NEAR_EQL`, `BELOW_EQL`, `NEAR_SWING_HIGH`, `ABOVE_SWING_HIGH`, `NEAR_SWING_LOW`, `BELOW_SWING_LOW`.
- `LIQUIDITY_RUN_CANDLE` para velas de desplazamiento fuerte que avanzan hacia un pool de liquidez activo.
- `PREV_DAILY_WICK_HIGH`, `PREV_DAILY_BODY_HIGH`, `PREV_DAILY_BODY_LOW`, `PREV_DAILY_WICK_LOW` y contexto `NEAR_DAILY_BODY`, `INSIDE_DAILY_BODY`, `NEAR_DAILY_WICK`, `INSIDE_UPPER_WICK`, `INSIDE_LOWER_WICK`, `ABOVE_DAILY_HIGH`, `BELOW_DAILY_LOW`.
- `PDH`, `PDL`, `PWH`, `PWL`, `PMH`, `PML`, segun disponibilidad del historico.
- `HTF_BSL`, `HTF_SSL`, `HTF_EQH`, `HTF_EQL`, con `source_timeframe`.

## Render Dinamico

El frontend sigue usando `/api/overlays` para dibujar. Ese endpoint ya trabaja por ventana visible mas lookback, cachea chunks y recorta shapes antes de enviarlas.

Los overlays se anclan por indice absoluto y timestamp real (`x1_abs_index`, `x2_abs_index`, `x1_time`, `x2_time`). Al hacer pan o zoom, el frontend solicita nuevas ventanas con debounce y cancela requests anteriores.

Las capas nuevas entran por la misma mecanica de render que SMC y Liquidity:

- Strong/Weak se dibuja como labels de pivots SMC y se controla con `smc_strong_weak`.
- Internal/Swing structure se filtra con `smc_internal` y `smc_swing`.
- Previous High/Low se dibuja como lineas y labels anclados al rango visible y se controla con `smc_prev_hl`.
- Premium/Discount se genera aunque no exista un fib set activo, usando el rango estructural confirmado mas reciente como fallback.

## No Repaint

- Un swing solo existe cuando se confirman `SWING_K` velas posteriores.
- El evento puede dibujarse en el tiempo del swing, pero conserva `confirmation_time`.
- Un pivot strong/weak confirmado no se mueve; si queda roto, se conserva `broken_time` y `broken_by_event_id`.
- BOS, CHoCH y MSS se confirman por cierre de vela.
- FVG, OB y zonas conservan su origen historico; si se mitigan o invalidan, cambia su `status` y su `end_time`, no se borra el evento original.
- Replay usa `replay_index` para cortar candles, overlays y eventos.

## HTF Liquidity

La liquidez HTF se calcula solo con velas HTF cerradas al tiempo visible. Cada nivel proyectado incluye `source_timeframe` y se devuelve como shape y como evento `HTF_BSL`, `HTF_SSL`, `HTF_EQH` o `HTF_EQL`.

## Previous High/Low

PDH/PDL y PWH/PWL se calculan desde velas `D` y `W` cerradas antes del rango visible. PMH/PML se calculan desde velas diarias del mes previo cuando el CSV contiene ese historico.

Estas lineas se proyectan solo dentro de la ventana visible para no crear miles de shapes largos. El origen temporal queda en `metadata.period_time` del evento y en `source_timeframe`.

## Performance

- Las velas/ATR se cachean por timeframe.
- Los overlays se cachean por timeframe y ventana visible.
- Los eventos SMC se cachean por symbol/timeframe/rango/limit.
- El frontend no recalcula indicadores; solo filtra capas visuales.
- Los payloads de eventos tienen limite configurable (`maxEventsPerRequest`, actualmente 2000) para evitar enviar miles de objetos innecesarios.
- Las clasificaciones contextuales se calculan en backend al construir la ventana y no en cada render del canvas.

## Pruebas

```bash
perl backend/test_smc_suite.pl
perl backend/test_timeframes.pl
perl backend/test_atr.pl
perl backend/test_marketdata.pl
perl backend/test_manager.pl
```

`backend/test_lectura.pl` depende del fixture historico `data/2026_03.csv`; si ese CSV no existe, la prueba falla antes de tocar la logica SMC.

## Limitaciones Conocidas

- `symbol` es una etiqueta logica; el proyecto aun carga un CSV fijo en `backend/app.pl`.
- Los Order Blocks siguen viviendo en `Strategy_Builder.pm` para no duplicar el sistema visual; el endpoint los normaliza como eventos SMC.
- La liquidez HTF se proyecta como niveles activos. No se modela aun una maquina completa de sweeps HTF sobre LTF.
- PMH/PML solo aparecen si el dataset contiene un mes anterior al rango visible.
- No hay persistencia de eventos en disco; la cache vive en memoria del proceso.
