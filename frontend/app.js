// ============================================================
//  app.js -- Orquestador del frontend.
//  Gestiona timeframes, replay y conexion con el ChartEngine.
// ============================================================

"use strict";

const App = { timeframe: "1m", data: null, overlays: null, engine: null, els: {} };

// ---- Estado del Replay ----
const Replay = {
  active:    false,
  index:     0,
  total:     0,
  playing:   false,
  _timer:    null,
  STEP_FAST: 10,
  SPEED_MS:  400,
};

// ============================================================
//  API helpers
// ============================================================

async function fetchData(tf, replayIndex) {
  const ri = replayIndex != null ? `&replay_index=${replayIndex}` : '';
  const resp = await fetch(`/api/candles?tf=${tf}${ri}`);
  if (!resp.ok) throw new Error(`candles API respondio ${resp.status}`);
  return resp.json();
}

async function fetchOverlays(tf, replayIndex) {
  const ri = replayIndex != null ? `&replay_index=${replayIndex}` : '';
  const resp = await fetch(`/api/overlays?tf=${tf}${ri}`);
  if (!resp.ok) throw new Error(`overlays API respondio ${resp.status}`);
  return resp.json();
}

async function loadTimeframe(tf) {
  App.timeframe = tf;
  [App.data, App.overlays] = await Promise.all([fetchData(tf), fetchOverlays(tf)]);
  console.log(
    `[${tf}] ${App.data.candles.length} velas | ` +
    `regime: ${App.overlays.market_regime?.state} (${App.overlays.market_regime?.confidence_score})`
  );
}

// ============================================================
//  Replay
// ============================================================

function replayEnter() {
  if (!App.data) return;
  Replay.active = true;
  Replay.total  = App.data.candles.length - 1;
  // Empieza a mitad del dataset para que haya historia visible
  Replay.index  = Math.max(5, Math.floor(Replay.total * 0.5));
  _replayShowControls(true);
  _replayFetch();
}

function replayExit() {
  _replayPause();
  Replay.active = false;
  _replayShowControls(false);
  // Restaurar datos completos
  App.engine.set_market(App.data);
  App.engine.set_overlays(App.overlays);
  App.engine.offset = 0;
  App.engine.request_render();
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
  if (Replay.playing) {
    _replayPause();
    return;
  }
  Replay.playing = true;
  document.getElementById('btn-rplay').textContent = '⏸'; // ⏸
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
  if (btn) btn.innerHTML = '&#x25B6;'; // ▶
}

async function _replayFetch() {
  try {
    const [cd, ov] = await Promise.all([
      fetchData(App.timeframe, Replay.index),
      fetchOverlays(App.timeframe, Replay.index),
    ]);
    App.engine.set_market(cd);
    App.engine.set_overlays(ov);
    App.engine.offset = 0;
    App.engine.request_render();
    _replayUpdateInfo();
  } catch (e) {
    console.error('Replay fetch error:', e);
  }
}

function _replayUpdateInfo() {
  const info = document.getElementById('replay-info');
  if (!info) return;
  const c = App.data.candles[Replay.index];
  const ts = c ? c.time.slice(0, 16).replace('T', ' ') : '';
  info.textContent = `${Replay.index + 1} / ${App.data.candles.length}  ${ts}`;
}

// ============================================================
//  Timeframe
// ============================================================

function highlightTF(tf) {
  document.querySelectorAll('.tf-btn').forEach(b => b.classList.toggle('active', b.dataset.tf === tf));
}

async function changeTimeframe(tf) {
  if (tf === App.timeframe && App.data && !Replay.active) return;
  if (Replay.active) replayExit();
  try {
    await loadTimeframe(tf);
    App.engine.set_market(App.data);
    App.engine.set_overlays(App.overlays);
    App.engine.reset_view();
    highlightTF(tf);
  } catch (err) {
    console.error('Error cambiando timeframe:', err);
  }
}

// ============================================================
//  Inicializacion
// ============================================================

function init() {
  App.els.priceCanvas  = document.getElementById('price-canvas');
  App.els.atrCanvas    = document.getElementById('atr-canvas');
  App.els.statusHover  = document.getElementById('status-hover');
  App.els.statusWindow = document.getElementById('status-window');
  App.els.statusbar    = document.getElementById('statusbar');

  App.engine = new ChartEngine(App.data, {
    priceCanvas:  App.els.priceCanvas,
    atrCanvas:    App.els.atrCanvas,
    statusHover:  App.els.statusHover,
    statusWindow: App.els.statusWindow,
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
      if (k === 'ArrowLeft')  { e.preventDefault(); _replayStep(-1); }
      else if (k === 'ArrowRight') { e.preventDefault(); _replayStep(+1); }
      else if (k === ' ')     { e.preventDefault(); _replayPlay(); }
      else if (k === 'Escape') replayExit();
    } else {
      if (k === 'r' || k === 'R') App.engine.reset_view();
      else if (k === 'q' || k === 'Q') {
        App._quit = true;
        App.els.statusHover.textContent = 'Sesion detenida (Q). Recarga la pagina para reanudar.';
        window.close();
      }
    }
  });

  console.log('App lista: TF, replay, teclado y overlays conectados');
  window.addEventListener('resize', () => App.engine.request_render());
}

window.addEventListener('DOMContentLoaded', () => {
  loadTimeframe(App.timeframe).then(() => init()).catch(e => console.error('Error:', e));
});
