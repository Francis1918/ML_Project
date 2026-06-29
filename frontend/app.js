// ============================================================
//  app.js -- Orquestador del frontend.
//  Optimizaciones:
//  - Cache por TF: no re-fetcha si el TF ya fue cargado.
//  - AbortController: cancela fetch anterior al cambiar TF.
//  - API ventaneada: pide solo las ultimas DEFAULT_LIMIT velas.
//  - Replay: fetch ventaneado alrededor del replay_index.
//  - performance.now() en fetch y render para depuracion.
// ============================================================

"use strict";

const App = { timeframe: "1m", data: null, overlays: null, engine: null, els: {} };

// Cache por TF y por rangos. Las velas se unen en un buffer contiguo
// y los overlays se cachean por rango visible absoluto.
const TFCache = {};

// AbortController activos: velas y overlays viajan separados para que
// el primer render no espere los indicadores pesados.
let _fetchController = null;
let _overlayController = null;
let _rangeController = null;
let _overlayDebounce = null;

// Replay
const Replay = {
  active:    false,
  index:     0,
  total:     0,
  playing:   false,
  _timer:    null,
  _ctrl:     null,   // AbortController propio del replay
  STEP_FAST: 10,
  SPEED_MS:  400,
};

// Carga normal, replay y overlays viajan por ventanas acotadas.
const WINDOW_LIMIT = 500;
const EDGE_LOAD_THRESHOLD = 80;
const OVERLAY_DEBOUNCE_MS = 140;
const OVERLAY_VIEW_PADDING = 250;


// Estado del menu multi-select de overlays. Vive en el frontend:
// no cambia el cálculo del backend, solo filtra qué shapes dibuja ChartEngine.
function _layerItemIsChecked(item) {
  return item.getAttribute('aria-checked') !== 'false';
}

function _setLayerItemChecked(item, checked) {
  item.setAttribute('aria-checked', checked ? 'true' : 'false');
  item.classList.toggle('is-off', !checked);
  const check = item.querySelector('.overlay-check');
  if (check) check.textContent = checked ? '✓' : '';
}

function readOverlayVisibilityFromUI() {
  const state = {};
  document.querySelectorAll('[data-layer-toggle]').forEach(item => {
    state[item.dataset.layerToggle] = _layerItemIsChecked(item);
  });
  return state;
}

function _syncOverlayControlStates() {
  const controls = document.getElementById('overlay-controls');
  if (!controls) return;

  const smcAllItem = controls.querySelector('[data-layer-toggle="smc_all"]');
  const liqAllItem = controls.querySelector('[data-layer-toggle="liq_all"]');
  const strategyAllItem = controls.querySelector('[data-layer-toggle="strategy_all"]');
  const smcAll = smcAllItem ? _layerItemIsChecked(smcAllItem) : true;
  const liqAll = liqAllItem ? _layerItemIsChecked(liqAllItem) : true;
  const strategyAll = strategyAllItem ? _layerItemIsChecked(strategyAllItem) : true;

  controls.querySelectorAll('[data-layer-parent="smc_all"]').forEach(item => {
    item.classList.toggle('is-muted', !smcAll);
    item.setAttribute('aria-disabled', smcAll ? 'false' : 'true');
  });

  controls.querySelectorAll('[data-layer-parent="liq_all"]').forEach(item => {
    item.classList.toggle('is-muted', !liqAll);
    item.setAttribute('aria-disabled', liqAll ? 'false' : 'true');
  });

  controls.querySelectorAll('[data-layer-parent="strategy_all"]').forEach(item => {
    item.classList.toggle('is-muted', !strategyAll);
    item.setAttribute('aria-disabled', strategyAll ? 'false' : 'true');
  });
}

function applyOverlayVisibilityFromUI() {
  if (!App.engine) return;
  App.engine.set_overlay_visibility(readOverlayVisibilityFromUI());
}

function initOverlayControls() {
  const controls = document.getElementById('overlay-controls');
  if (!controls) return;

  const root = controls.querySelector('.overlay-root');
  const setExpanded = (expanded) => {
    if (root) root.setAttribute('aria-expanded', expanded ? 'true' : 'false');
  };

  controls.addEventListener('mouseenter', () => setExpanded(true));
  controls.addEventListener('mouseleave', () => setExpanded(false));

  controls.querySelectorAll('[data-layer-toggle]').forEach(item => {
    _setLayerItemChecked(item, _layerItemIsChecked(item));

    item.addEventListener('click', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      _setLayerItemChecked(item, !_layerItemIsChecked(item));
      _syncOverlayControlStates();
      applyOverlayVisibilityFromUI();
    });
  });

  // Cierre rapido si el usuario pulsa Escape mientras navega el menu.
  controls.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') {
      controls.blur();
      setExpanded(false);
    }
  });

  _syncOverlayControlStates();
  applyOverlayVisibilityFromUI();
}

// ============================================================
//  API helpers
// ============================================================

async function fetchData(tf, extraParams = {}, signal) {
  const t0  = performance.now();
  const qs  = new URLSearchParams({ tf, limit: WINDOW_LIMIT, ...extraParams });
  const opt = signal ? { signal } : {};
  const resp = await fetch(`/api/candles?${qs}`, opt);
  if (!resp.ok) throw new Error(`candles API respondio ${resp.status}`);
  const t1 = performance.now();
  const data = await resp.json();
  const t2 = performance.now();
  console.debug(
    `[fetch candles] ${tf}: red=${(t1-t0).toFixed(0)}ms parse=${(t2-t1).toFixed(0)}ms` +
    ` velas=${data.candles.length} total=${data.total}`
  );
  return data;
}

async function fetchOverlays(tf, extraParams = {}, signal) {
  const t0  = performance.now();
  const qs  = new URLSearchParams({ tf, limit: WINDOW_LIMIT, ...extraParams });
  const opt = signal ? { signal } : {};
  const resp = await fetch(`/api/overlays?${qs}`, opt);
  if (!resp.ok) throw new Error(`overlays API respondio ${resp.status}`);
  const t1 = performance.now();
  const data = await resp.json();
  const t2 = performance.now();
  console.debug(
    `[fetch overlays] ${tf}: red=${(t1-t0).toFixed(0)}ms parse=${(t2-t1).toFixed(0)}ms`
  );
  return data;
}

function _tfCache(tf) {
  if (!TFCache[tf]) {
    TFCache[tf] = {
      timeframe: tf,
      candlesByAbs: new Map(),
      atrByAbs: new Map(),
      overlayChunks: new Map(),
      loadedStart: null,
      loadedEnd: null,
      total: 0,
      data: null,
    };
  }
  return TFCache[tf];
}

function _normalizeCandleData(data) {
  const base = data.win_start ?? 0;
  data.candles.forEach((c, i) => {
    if (c.abs_index === undefined || c.abs_index === null) c.abs_index = base + i;
  });
  data.win_end = data.win_end ?? (base + data.candles.length - 1);
  return data;
}

function _buildDataFromEntry(entry) {
  if (!entry.candlesByAbs.size) return null;
  const keys = [...entry.candlesByAbs.keys()].sort((a, b) => a - b);
  const start = keys[0];
  const end = keys[keys.length - 1];
  const candles = [];
  const atr = [];

  for (let abs = start; abs <= end; abs++) {
    if (!entry.candlesByAbs.has(abs)) break;
    candles.push(entry.candlesByAbs.get(abs));
    atr.push(entry.atrByAbs.get(abs));
  }

  const winEnd = start + candles.length - 1;
  entry.loadedStart = start;
  entry.loadedEnd = winEnd;
  entry.data = {
    timeframe: entry.timeframe,
    candles,
    atr,
    total: entry.total,
    win_start: start,
    win_end: winEnd,
    first_index: 0,
    last_index: candles.length - 1,
    max_visible_index: candles.length - 1,
    has_more_left: start > 0,
    has_more_right: entry.total ? winEnd < entry.total - 1 : false,
  };
  return entry.data;
}

function _mergeCandleData(entry, data) {
  _normalizeCandleData(data);
  const oldStart = entry.loadedStart;
  const oldEnd = entry.loadedEnd;
  entry.total = data.total ?? entry.total;

  data.candles.forEach((c, i) => {
    const abs = c.abs_index;
    entry.candlesByAbs.set(abs, c);
    entry.atrByAbs.set(abs, data.atr?.[i]);
  });

  const merged = _buildDataFromEntry(entry);
  return {
    data: merged,
    addedLeft: oldStart === null ? 0 : Math.max(0, oldStart - entry.loadedStart),
    addedRight: oldEnd === null ? 0 : Math.max(0, entry.loadedEnd - oldEnd),
  };
}

function _overlayKey(startAbs, endAbs, replayIndex = null) {
  return `${startAbs}:${endAbs}:${replayIndex ?? 'live'}`;
}

function _overlayRange(overlays) {
  const r = overlays?._requested_abs_range ?? overlays?.visible_abs_range;
  if (!r) return null;
  return {
    start: r.start ?? r.absFirst ?? 0,
    end: r.end ?? r.absLast ?? 0,
  };
}

function _overlaysCoverRange(overlays, range) {
  const r = _overlayRange(overlays);
  if (!r || !range) return false;
  return r.start <= range.absFirst && r.end >= range.absLast;
}

function _overlayRequestRangeForVisible(range) {
  const total = range.total ?? App.data?.total ?? 0;
  const maxAbs = total > 0 ? total - 1 : range.absLast;
  return {
    start: Math.max(0, range.absFirst - OVERLAY_VIEW_PADDING),
    end: Math.min(maxAbs, range.absLast + OVERLAY_VIEW_PADDING),
  };
}

function _findCoveringOverlay(entry, startAbs, endAbs, replayIndex = null) {
  if (replayIndex !== null) return null;
  for (const overlays of entry.overlayChunks.values()) {
    const r = _overlayRange(overlays);
    if (r && r.start <= startAbs && r.end >= endAbs) return overlays;
  }
  return null;
}

function _currentVisibleAbsRange() {
  if (App.engine?.get_visible_abs_range) return App.engine.get_visible_abs_range();
  if (!App.data) return null;
  return {
    first: 0,
    last: App.data.candles.length - 1,
    absFirst: App.data.win_start ?? 0,
    absLast: App.data.win_end ?? ((App.data.win_start ?? 0) + App.data.candles.length - 1),
  };
}

async function loadTimeframe(tf) {
  const cached = _tfCache(tf);
  if (cached.data) {
    App.timeframe = tf;
    App.data      = cached.data;
    App.overlays  = null;
    console.debug(`[TFCache] ${tf} candles servido desde cache`);
    return;
  }

  // Cancelar fetch anterior si sigue en curso
  if (_fetchController) {
    _fetchController.abort();
    _fetchController = null;
  }
  _fetchController = new AbortController();
  const signal = _fetchController.signal;

  App.timeframe = tf;
  App.overlays = null;
  const data = await fetchData(tf, {}, signal);

  const entry = _tfCache(tf);
  _mergeCandleData(entry, data);
  App.data = entry.data;
  App.overlays = null;

  console.log(
    `[${tf}] ${data.candles.length} velas (total=${data.total})`
  );
}

async function loadOverlaysFor(tf, extraParams = {}) {
  if (extraParams.start !== undefined || extraParams.end !== undefined) {
    return loadOverlaysForRange(tf, extraParams.start, extraParams.end, {
      replayIndex: extraParams.replay_index,
    });
  }

  const range = _currentVisibleAbsRange();
  if (!range) return null;
  const req = _overlayRequestRangeForVisible(range);
  return loadOverlaysForRange(tf, req.start, req.end);
}

async function loadOverlaysForRange(tf, startAbs, endAbs, opts = {}) {
  if (startAbs === undefined || endAbs === undefined) return null;
  startAbs = Math.max(0, Math.floor(startAbs));
  endAbs = Math.max(startAbs, Math.floor(endAbs));

  const replayIndex = opts.replayIndex ?? null;
  const cacheable = replayIndex === null && !Replay.active;
  const entry = _tfCache(tf);
  const key = _overlayKey(startAbs, endAbs, replayIndex);
  const cachedOverlay = cacheable
    ? (entry.overlayChunks.get(key) ?? _findCoveringOverlay(entry, startAbs, endAbs, replayIndex))
    : null;
  if (cachedOverlay) {
    const overlays = cachedOverlay;
    if (App.timeframe === tf && !Replay.active) {
      App.overlays = overlays;
      App.engine?.set_overlays(overlays);
      App.engine?.request_render();
    }
    return overlays;
  }

  if (_overlayController) {
    _overlayController.abort();
    _overlayController = null;
  }
  _overlayController = new AbortController();
  const signal = _overlayController.signal;

  try {
    const params = { start: startAbs, end: endAbs };
    if (replayIndex !== null) params.replay_index = replayIndex;
    const overlays = await fetchOverlays(tf, params, signal);
    overlays._requested_abs_range = { start: startAbs, end: endAbs };
    if (cacheable) entry.overlayChunks.set(key, overlays);
    if (App.timeframe === tf && !Replay.active) {
      const current = _currentVisibleAbsRange();
      if (current && !_overlaysCoverRange(overlays, current)) return overlays;
      App.overlays = overlays;
      App.engine?.set_overlays(overlays);
      App.engine?.request_render();
    }
    return overlays;
  } catch (err) {
    if (err.name !== 'AbortError') console.error('Error cargando overlays:', err);
    return null;
  }
}

function _scheduleVisibleOverlayLoad(range) {
  if (Replay.active || !range) return;
  clearTimeout(_overlayDebounce);
  _overlayDebounce = setTimeout(() => {
    const latest = _currentVisibleAbsRange();
    if (!latest || Replay.active) return;
    const req = _overlayRequestRangeForVisible(latest);
    loadOverlaysForRange(App.timeframe, req.start, req.end);
  }, OVERLAY_DEBOUNCE_MS);
}

async function _maybeLoadMoreCandles(range) {
  if (Replay.active || _rangeController || !App.data || !range) return;

  const data = App.data;
  const tf = App.timeframe;
  let params = null;
  let direction = null;

  if (range.first <= EDGE_LOAD_THRESHOLD && data.has_more_left) {
    const end = (data.win_start ?? 0) - 1;
    const start = Math.max(0, end - WINDOW_LIMIT + 1);
    params = { start, end };
    direction = 'left';
  } else if (range.last >= data.candles.length - 1 - EDGE_LOAD_THRESHOLD && data.has_more_right) {
    const start = (data.win_end ?? ((data.win_start ?? 0) + data.candles.length - 1)) + 1;
    const end = Math.min((data.total ?? start) - 1, start + WINDOW_LIMIT - 1);
    params = { start, end };
    direction = 'right';
  }

  if (!params || params.end < params.start) return;

  _rangeController = new AbortController();
  const signal = _rangeController.signal;
  try {
    const chunk = await fetchData(tf, params, signal);
    if (signal.aborted || Replay.active || App.timeframe !== tf) return;

    const entry = _tfCache(tf);
    const merged = _mergeCandleData(entry, chunk);
    App.data = merged.data;
    App.engine.set_market(App.data);

    // Si agregamos velas a la derecha, mantener el mismo rango visible.
    // Al prepender a la izquierda, el offset actual ya conserva la vista.
    if (direction === 'right' && merged.addedRight > 0) {
      App.engine.offset += merged.addedRight;
    }

    App.engine.request_render();
    _scheduleVisibleOverlayLoad(_currentVisibleAbsRange());
  } catch (err) {
    if (err.name !== 'AbortError') console.error('Error cargando rango:', err);
  } finally {
    _rangeController = null;
  }
}

function handleViewChange(range) {
  if (Replay.active) return;
  if (App.overlays && !_overlaysCoverRange(App.overlays, range)) {
    App.overlays = null;
    App.engine?.set_overlays(null);
    App.engine?.request_render();
  }
  _maybeLoadMoreCandles(range);
  _scheduleVisibleOverlayLoad(range);
}

// ============================================================
//  Replay
// ============================================================

function replayEnter() {
  if (!App.data) return;
  if (_overlayController) { _overlayController.abort(); _overlayController = null; }
  Replay.active = true;
  // Usar el total real del dataset (no el de la ventana)
  Replay.total = (App.data.total ?? App.data.candles.length) - 1;
  // Empezar a mitad del dataset para que haya historia visible
  Replay.index = Math.max(5, Math.floor(Replay.total * 0.5));
  _replayShowControls(true);
  _replayFetch();
}

function replayExit(reloadOverlays = true) {
  _replayPause();
  if (Replay._ctrl) { Replay._ctrl.abort(); Replay._ctrl = null; }
  Replay.active = false;
  _replayShowControls(false);
  // Restaurar los datos de la ventana normal del TF actual
  App.engine.set_market(App.data);
  App.engine.set_overlays(App.overlays);
  App.engine.offset = 0;
  App.engine.request_render();
  if (reloadOverlays && !App.overlays) loadOverlaysFor(App.timeframe);
}

function _replayShowControls(on) {
  document.getElementById('replay-controls').classList.toggle('hidden', !on);
  document.getElementById('btn-replay-on').classList.toggle('active', on);
}

function _replayStep(delta) {
  Replay.index = Math.max(0, Math.min(Replay.total, Replay.index + delta));
  _replayFetch();
}

function _replayPlay() {
  if (Replay.playing) { _replayPause(); return; }
  Replay.playing = true;
  document.getElementById('btn-rplay').textContent = '⏸';
  Replay._timer = setInterval(() => {
    if (Replay.index >= Replay.total) { _replayPause(); return; }
    Replay.index++;
    _replayFetch();
  }, Replay.SPEED_MS);
}

function _replayPause() {
  Replay.playing = false;
  clearInterval(Replay._timer);
  Replay._timer = null;
  const btn = document.getElementById('btn-rplay');
  if (btn) btn.innerHTML = '&#x25B6;';
}

async function _replayFetch() {
  // Cancelar peticion de replay anterior si no termino
  if (Replay._ctrl) { Replay._ctrl.abort(); }
  Replay._ctrl = new AbortController();
  const signal = Replay._ctrl.signal;

  try {
    const ri        = Replay.index;          // indice absoluto
    const winStart  = Math.max(0, ri - (WINDOW_LIMIT - 1));
    const cd = await fetchData(App.timeframe, { start: winStart, end: ri }, signal);
    App.engine.set_market(cd);
    App.engine.set_overlays(null);
    App.engine.offset = 0;
    App.engine.request_render();
    _replayUpdateInfo(cd);

    const ov = await fetchOverlays(
      App.timeframe,
      { start: winStart, end: ri, replay_index: ri },
      signal
    );
    if (signal.aborted || !Replay.active) return;
    App.engine.set_overlays(ov);
    App.engine.request_render();
  } catch (e) {
    if (e.name !== 'AbortError') console.error('Replay fetch error:', e);
  }
}

function _replayUpdateInfo(cd) {
  const info = document.getElementById('replay-info');
  if (!info) return;
  const total = App.data.total ?? App.data.candles.length;
  // La ultima vela en la ventana de replay ES la vela en Replay.index
  const lastC = cd?.candles?.[cd.candles.length - 1];
  const ts    = lastC ? lastC.time.slice(0, 16).replace('T', ' ') : '';
  info.textContent = `${Replay.index + 1} / ${total}  ${ts}`;
}

// ============================================================
//  Timeframe
// ============================================================

function highlightTF(tf) {
  document.querySelectorAll('.tf-btn').forEach(b =>
    b.classList.toggle('active', b.dataset.tf === tf));
}

async function changeTimeframe(tf) {
  if (tf === App.timeframe && App.data && !Replay.active) {
    loadOverlaysFor(tf);
    return;
  }
  if (Replay.active) replayExit(false);
  try {
    await loadTimeframe(tf);
    App.engine.set_market(App.data);
    App.engine.set_overlays(App.overlays);
    App.engine.reset_view();
    highlightTF(tf);
    loadOverlaysFor(tf);
  } catch (err) {
    if (err.name !== 'AbortError') console.error('Error cambiando timeframe:', err);
  }
}

// ============================================================
//  Inicializacion
// ============================================================

function init() {
  App.els.priceCanvas     = document.getElementById('price-canvas');
  App.els.atrCanvas       = document.getElementById('atr-canvas');
  App.els.priceCrosshair  = document.getElementById('price-xhair');
  App.els.atrCrosshair    = document.getElementById('atr-xhair');
  App.els.statusHover     = document.getElementById('status-hover');
  App.els.statusWindow    = document.getElementById('status-window');
  App.els.statusbar       = document.getElementById('statusbar');

  App.engine = new ChartEngine(App.data, {
    priceCanvas:    App.els.priceCanvas,
    atrCanvas:      App.els.atrCanvas,
    priceCrosshair: App.els.priceCrosshair,
    atrCrosshair:   App.els.atrCrosshair,
    statusHover:    App.els.statusHover,
    statusWindow:   App.els.statusWindow,
  });
  App.engine.set_overlays(App.overlays);
  App.engine.set_view_change_handler?.(handleViewChange);
  initOverlayControls();
  App.engine.render();
  App.engine.bind_events();

  // Botones de timeframe
  document.querySelectorAll('.tf-btn').forEach(btn =>
    btn.addEventListener('click', () => changeTimeframe(btn.dataset.tf)));

  // Modo Auto / Manual
  const btnAuto   = document.getElementById('btn-auto');
  const btnManual = document.getElementById('btn-manual');
  const btnFib = document.getElementById('btn-fib');
  const btnFibUndo = document.getElementById('btn-fib-undo');
  const btnFibClear = document.getElementById('btn-fib-clear');
  function setMode(mode) {
    App.engine.set_mode(mode);
    btnAuto.classList.toggle('active', mode === 'auto');
    btnManual.classList.toggle('active', mode === 'manual');
  }
  btnAuto.addEventListener('click',   () => setMode('auto'));
  btnManual.addEventListener('click', () => setMode('manual'));
  function setFibTool(on) {
    App.engine.set_tool(on ? 'fib' : 'cursor');
    btnFib?.classList.toggle('active', App.engine.get_tool() === 'fib');
  }
  btnFib?.addEventListener('click', () => setFibTool(App.engine.get_tool() !== 'fib'));
  btnFibUndo?.addEventListener('click', () => App.engine.undo_manual_fib());
  btnFibClear?.addEventListener('click', () => App.engine.clear_manual_fibs());

  // Controles de Replay
  document.getElementById('btn-replay-on').addEventListener('click', replayEnter);
  document.getElementById('btn-rexit'    ).addEventListener('click', replayExit);
  document.getElementById('btn-rplay'    ).addEventListener('click', _replayPlay);
  document.getElementById('btn-rbk1'    ).addEventListener('click', () => _replayStep(-1));
  document.getElementById('btn-rbk10'   ).addEventListener('click', () => _replayStep(-Replay.STEP_FAST));
  document.getElementById('btn-rfwd1'   ).addEventListener('click', () => _replayStep(+1));
  document.getElementById('btn-rfwd10'  ).addEventListener('click', () => _replayStep(+Replay.STEP_FAST));

  // Reset y ayuda
  document.getElementById('btn-reset').addEventListener('click', () => App.engine.reset_view());
  document.getElementById('btn-help' ).addEventListener('click', () =>
    App.els.statusbar.classList.toggle('hidden'));

  // Teclado
  window.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
    const k = e.key;
    if (Replay.active) {
      if      (k === 'ArrowLeft')  { e.preventDefault(); _replayStep(-1); }
      else if (k === 'ArrowRight') { e.preventDefault(); _replayStep(+1); }
      else if (k === ' ')          { e.preventDefault(); _replayPlay(); }
      else if (k === 'Escape')     replayExit();
    } else {
      if (k === 'Escape' && App.engine.get_tool?.() === 'fib') {
        e.preventDefault();
        setFibTool(false);
        return;
      }
      if ((k === 'Delete' || k === 'Backspace') && App.engine.get_tool?.() === 'fib') {
        e.preventDefault();
        App.engine.undo_manual_fib();
        return;
      }
      if (k === 'r' || k === 'R') App.engine.reset_view();
      else if (k === 'q' || k === 'Q') {
        App.els.statusHover.textContent = 'Sesion detenida (Q). Recarga la pagina para reanudar.';
        _replayPause();
      }
    }
  });

  console.log('App lista: TF, replay, teclado y overlays conectados');
  window.addEventListener('resize', () => App.engine.request_render());
}

window.addEventListener('DOMContentLoaded', () => {
  loadTimeframe(App.timeframe)
    .then(() => {
      init();
      highlightTF(App.timeframe);
      loadOverlaysFor(App.timeframe);
    })
    .catch(e => console.error('Error:', e));
});
