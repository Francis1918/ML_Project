// ============================================================
//  app.js -- Orquestador del frontend.
//  Conecta la interfaz (botones, teclado) con el ChartEngine.
// ============================================================

"use strict";

const App = { timeframe: "1m", data: null, engine: null, els: {} };

async function fetchData(tf) {
  const resp = await fetch(`/api/candles?tf=${tf}`);
  if (!resp.ok) throw new Error(`La API respondio ${resp.status}`);
  return resp.json();
}

async function loadTimeframe(tf) {
  App.timeframe = tf;
  App.data = await fetchData(tf);
  console.log(`Datos ${tf}: ${App.data.candles.length} velas, ${App.data.atr.length} ATR`);
}

// Resalta el boton del timeframe activo
function highlightTF(tf) {
  document.querySelectorAll(".tf-btn").forEach((b) => {
    b.classList.toggle("active", b.dataset.tf === tf);
  });
}

// Cambia de timeframe: trae datos, los pasa al motor, resetea y redibuja
async function changeTimeframe(tf) {
  if (tf === App.timeframe && App.data) return;  // ya estamos en ese TF
  try {
    await loadTimeframe(tf);
    App.engine.set_market(App.data);
    App.engine.reset_view();   // ya hace request_render()
    highlightTF(tf);
  } catch (err) {
    console.error("Error cambiando timeframe:", err);
  }
}

function init() {
  App.els.priceCanvas  = document.getElementById("price-canvas");
  App.els.atrCanvas    = document.getElementById("atr-canvas");
  App.els.statusHover  = document.getElementById("status-hover");
  App.els.statusWindow = document.getElementById("status-window");
  App.els.statusbar    = document.getElementById("statusbar");

  App.engine = new ChartEngine(App.data, {
    priceCanvas:  App.els.priceCanvas,
    atrCanvas:    App.els.atrCanvas,
    statusHover:  App.els.statusHover,
    statusWindow: App.els.statusWindow,
  });
  App.engine.render();
  App.engine.bind_events();

  // --- Botones de timeframe ---
  document.querySelectorAll(".tf-btn").forEach((btn) => {
    btn.addEventListener("click", () => changeTimeframe(btn.dataset.tf));
  });

  // --- Botones de modo Auto / Manual ---
  const btnAuto   = document.getElementById("btn-auto");
  const btnManual = document.getElementById("btn-manual");
  function setMode(mode) {
    App.engine.set_mode(mode);
    btnAuto  .classList.toggle("active", mode === "auto");
    btnManual.classList.toggle("active", mode === "manual");
  }
  btnAuto  .addEventListener("click", () => setMode("auto"));
  btnManual.addEventListener("click", () => setMode("manual"));

  // --- Boton Reset ---
  document.getElementById("btn-reset")
    .addEventListener("click", () => App.engine.reset_view());

  // --- Boton ? (muestra/oculta la barra de estado) ---
  document.getElementById("btn-help")
    .addEventListener("click", () => App.els.statusbar.classList.toggle("hidden"));

  // --- Atajos de teclado ---
  window.addEventListener("keydown", (e) => {
    // Ignora si se esta escribiendo en un campo de texto
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;

    const k = e.key.toLowerCase();
    if (k === "r") {
      App.engine.reset_view();
    } else if (k === "q") {
      // "Quit" adaptado al navegador: detiene la interaccion y avisa.
      App._quit = true;
      App.els.statusHover.textContent =
        "Sesion detenida (Q). Recarga la pagina para reanudar.";
      // Intento de cerrar la pestana (los navegadores suelen bloquearlo
      // si la pestana no fue abierta por script; es el comportamiento esperado).
      window.close();
    }
  });

  console.log("App lista: botones y teclado conectados");
  window.addEventListener("resize", () => App.engine.request_render());
}

window.addEventListener("DOMContentLoaded", () => {
  loadTimeframe(App.timeframe).then(() => init()).catch((err) => console.error("Error:", err));
});
