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

// Cache por TF para no re-fetchear al volver a un TF ya visitado
const TFCache = {};

// AbortController activos: velas y overlays viajan separados para que
// el primer render no espere los indicadores pesados.
let _fetchController = null;
let _overlayController = null;

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

// Replay/overlays siguen ventaneados; las velas normales se piden completas.
const WINDOW_LIMIT = 500;

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
  if (!TFCache[tf]) TFCache[tf] = {};
  return TFCache[tf];
}

async function loadTimeframe(tf) {
  const cached = TFCache[tf];
  if (cached?.data) {
    App.timeframe = tf;
    App.data      = cached.data;
    App.overlays  = cached.overlays ?? null;
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
  const data = await fetchData(tf, { all: 1 }, signal);

  const entry = _tfCache(tf);
  entry.data = data;
  App.data    = data;
  App.overlays = entry.overlays ?? null;

  console.log(
    `[${tf}] ${data.candles.length} velas (total=${data.total})`
  );
}

async function loadOverlaysFor(tf, extraParams = {}) {
  const cacheable = Object.keys(extraParams).length === 0;
  const cached = TFCache[tf];
  if (cacheable && cached?.overlays) {
    if (App.timeframe === tf && !Replay.active) {
      App.overlays = cached.overlays;
      App.engine?.set_overlays(App.overlays);
      App.engine?.request_render();
    }
    return cached.overlays;
  }

  if (_overlayController) {
    _overlayController.abort();
    _overlayController = null;
  }
  _overlayController = new AbortController();
  const signal = _overlayController.signal;

  try {
    const params = cacheable ? { absolute: 1 } : extraParams;
    const overlays = await fetchOverlays(tf, params, signal);
    if (cacheable) _tfCache(tf).overlays = overlays;
    if (App.timeframe === tf && !Replay.active) {
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
    if (!TFCache[tf]?.overlays) loadOverlaysFor(tf);
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
  App.engine.render();
  App.engine.bind_events();

  // Botones de timeframe
  document.querySelectorAll('.tf-btn').forEach(btn =>
    btn.addEventListener('click', () => changeTimeframe(btn.dataset.tf)));

  // Modo Auto / Manual
  const btnAuto   = document.getElementById('btn-auto');
  const btnManual = document.getElementById('btn-manual');
  function setMode(mode) {
    App.engine.set_mode(mode);
    btnAuto.classList.toggle('active', mode === 'auto');
    btnManual.classList.toggle('active', mode === 'manual');
  }
  btnAuto.addEventListener('click',   () => setMode('auto'));
  btnManual.addEventListener('click', () => setMode('manual'));

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
      if (k === 'r' || k === 'R') App.engine.reset_view();
      else if (k === 'q' || k === 'Q') {
        App.els.statusHover.textContent = 'Sesion detenida (Q). Recarga la pagina para reanudar.';
        window.close();
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
