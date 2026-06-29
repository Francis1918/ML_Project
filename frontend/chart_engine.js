"use strict";

// Colores del badge de MarketRegime
const REGIME_COLORS = {
  'UNKNOWN':          '#546E7A',
  'ZONA_INTERNA':     '#607D8B',
  'LIQUIDEZ_INTERNA': '#E65100',
  'LIQUIDEZ_EXTERNA': '#1565C0',
  'ZM_MANIPULATION':  '#6A1B9A',
  'TRANSITION':       '#00838F',
  'TR_BULLISH':       '#1B5E20',
  'TR_BEARISH':       '#B71C1C',
};

// Mapa de color_role → color hex (coincide con los roles definidos en Overlays/*.pm)
const OV_COLORS = {
  bsl:              '#EF5350',
  ssl:              '#26A69A',
  eqh:              '#FF9800',
  eql:              '#00BCD4',
  sweep_up:         '#EF5350',
  sweep_down:       '#26A69A',
  grab:             '#FF9800',
  run:              '#2196F3',
  pivot_hh:         '#26A69A',
  pivot_hl:         '#4CAF50',
  pivot_lh:         '#FF5722',
  pivot_ll:         '#EF5350',
  bos_bullish:      '#26A69A',
  bos_bearish:      '#EF5350',
  choch_bullish:    '#00BCD4',
  choch_bearish:    '#FF9800',
  fvg_bullish:      '#26A69A',
  fvg_bearish:      '#EF5350',
  fvg_high_reaction:'#FFD700',
  fib_level:        '#9E9E9E',
};

function _ov_dash(style) {
  if (style === 'dashed') return [5, 3];
  if (style === 'dotted') return [2, 2];
  return [];
}


// Estado visual por capa. Solo afecta el render: los indicadores siguen llegando
// completos desde el backend y no se recalcula nada por activar/desactivar capas.
const DEFAULT_OVERLAY_VISIBILITY = Object.freeze({
  smc_all:       true,
  smc_hh:        true,
  smc_hl:        true,
  smc_lh:        true,
  smc_ll:        true,
  smc_bos:       true,
  smc_choch:     true,
  smc_fvg:       true,
  smc_fib:       true,

  liq_all:       true,
  liq_bsl:       true,
  liq_ssl:       true,
  liq_eqh:       true,
  liq_eql:       true,
  liq_grab:      true,
  liq_sweep:     true,
  liq_run:       true,
  liq_htf:       true,

  market_regime: true,
});

// Dia de la semana (lun..dom) de una fecha ISO, sin influencia de la zona horaria.
function diaSemana(iso) {
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return "";
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).getUTCDay();
  return ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"][d];
}

const PRICE_AXIS_W = 60;
const TIME_AXIS_H  = 20;
const MIN_BARS = 2;
const MAX_BARS = 8000;
const MAX_HTF_LABELS = 10;
const MANUAL_FIB_LEVELS = Object.freeze([0, 0.236, 0.382, 0.5, 0.618, 0.786, 1]);

class ChartEngine {
  constructor(market, els) {
    this.market = market;
    this.els    = els;
    this.visible_bars = 120;
    this.offset       = 0;
    this.price_auto = true;
    this.price_min  = null;
    this.price_max  = null;
    this.atr_auto = true;
    this.atr_min  = null;
    this.atr_max  = null;
    this._dragX = false; this._dragY = false; this._dragYPanel = null;
    this._startX = 0; this._startY = 0; this._startOff = 0;
    this._startPMin = 0; this._startPMax = 0;
    this._renderPending = false;
    this._mouse = null;
    this._hoverIndex = null;
    this.priceScale = new Scales();
    this.atrScale   = new Scales();
    this.pricePanel = new PricePanel(els.priceCanvas, this.priceScale);
    this.atrPanel   = new ATRPanel(els.atrCanvas, this.atrScale);
    this._lastBarW = 8;
    this.mode = "auto";
    this.overlays = null;
    this.overlay_visibility = { ...DEFAULT_OVERLAY_VISIBILITY };
    this._onViewChange = null;
    this._lastViewSignature = "";
    this._absToLocal = new Map();
    this._timeToLocal = new Map();
    this.active_tool = "cursor";
    this.manual_fibs = [];
    this._fibAnchor = null;
    this._fibHoverAnchor = null;
    this._build_index_maps();
    this._apply_tool_cursor();
  }

  set_overlays(ov) { this.overlays = ov; }

  set_view_change_handler(fn) {
    this._onViewChange = typeof fn === "function" ? fn : null;
  }

  set_overlay_visibility(visibility = {}) {
    this.overlay_visibility = { ...DEFAULT_OVERLAY_VISIBILITY, ...visibility };
    this.request_render();
  }

  set_tool(tool) {
    this.active_tool = tool === "fib" ? "fib" : "cursor";
    if (this.active_tool !== "fib") {
      this._fibAnchor = null;
      this._fibHoverAnchor = null;
    }
    this._apply_tool_cursor();
    this.request_render();
  }

  get_tool() { return this.active_tool; }

  clear_manual_fibs() {
    const tf = this.market?.timeframe;
    this.manual_fibs = this.manual_fibs.filter(f => f.timeframe !== tf);
    this._fibAnchor = null;
    this._fibHoverAnchor = null;
    this.request_render();
  }

  undo_manual_fib() {
    const tf = this.market?.timeframe;
    for (let i = this.manual_fibs.length - 1; i >= 0; i--) {
      if (this.manual_fibs[i].timeframe === tf) {
        this.manual_fibs.splice(i, 1);
        break;
      }
    }
    this.request_render();
  }

  _apply_tool_cursor() {
    if (!this.els?.priceCanvas) return;
    this.els.priceCanvas.style.cursor = this.active_tool === "fib" ? "copy" : "crosshair";
  }

  set_mode(mode) {
    this.mode = mode;
    if (mode === "auto") {
      this.price_auto = true;
      this.atr_auto   = true;
    }
    this._clamp_offset();
    this.request_render();
  }

  set_market(market) {
    this.market = market;
    this._build_index_maps();
    this._clamp_bars();
    this._clamp_offset();
    this._lastViewSignature = "";
  }

  _build_index_maps() {
    this._absToLocal = new Map();
    this._timeToLocal = new Map();
    if (!this.market?.candles) return;
    const base = this.market.win_start ?? 0;
    for (let i = 0; i < this.market.candles.length; i++) {
      const c = this.market.candles[i];
      const abs = c.abs_index ?? (base + i);
      this._absToLocal.set(abs, i);
      if (c.time) this._timeToLocal.set(c.time, i);
    }
  }

  round(v) { return Math.round(v); }

  request_render() {
    if (this._renderPending) return;
    this._renderPending = true;
    requestAnimationFrame(() => { this._renderPending = false; this.render(); });
  }

  compute_window() {
    const n            = this.market.candles.length;
    const count        = Math.min(this.visible_bars, n);
    const virtualLast  = n - 1 - this.offset;
    const virtualFirst = virtualLast - count + 1;
    const first = Math.max(0, Math.min(n - 1, Math.floor(virtualFirst)));
    const last  = Math.max(0, Math.min(n - 1, Math.ceil(virtualLast)));
    return { first, last, virtualFirst, count };
  }

  get_visible_abs_range(win = null) {
    if (!this.market?.candles?.length) return null;
    win = win ?? this.compute_window();
    const firstC = this.market.candles[win.first];
    const lastC  = this.market.candles[win.last];
    const base = this.market.win_start ?? 0;
    return {
      first: win.first,
      last: win.last,
      count: win.count,
      absFirst: firstC?.abs_index ?? (base + win.first),
      absLast: lastC?.abs_index ?? (base + win.last),
      loadedStart: this.market.win_start ?? 0,
      loadedEnd: this.market.win_end ?? (base + this.market.candles.length - 1),
      total: this.market.total ?? this.market.candles.length,
      hasMoreLeft: !!this.market.has_more_left,
      hasMoreRight: !!this.market.has_more_right,
    };
  }

  _notify_view_change(win) {
    if (!this._onViewChange) return;
    const range = this.get_visible_abs_range(win);
    if (!range) return;
    const sig = [
      range.absFirst, range.absLast, range.loadedStart,
      range.loadedEnd, this.visible_bars, this.offset,
    ].join(":");
    if (sig === this._lastViewSignature) return;
    this._lastViewSignature = sig;
    this._onViewChange(range);
  }

  _clamp_offset() {
    const n      = this.market.candles.length;
    const count  = Math.min(this.visible_bars, n);
    const maxOff = Math.max(0, n - 2);
    const minOff = -(count - 2);
    if (this.offset < minOff) this.offset = minOff;
    if (this.offset > maxOff) this.offset = maxOff;
  }

  _clamp_bars() {
    const n = this.market.candles.length;
    const top = Math.min(MAX_BARS, n);
    if (this.visible_bars < MIN_BARS) this.visible_bars = MIN_BARS;
    if (this.visible_bars > top) this.visible_bars = top;
  }

  _fit_canvas(canvas) {
    const dpr  = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    const w    = Math.max(1, Math.floor(rect.width));
    const h    = Math.max(1, Math.floor(rect.height));
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
      canvas.width  = w * dpr;
      canvas.height = h * dpr;
    }
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    return { w, h };
  }

  // ============================================================
  //  Render completo (velas, ATR, overlays, eje de tiempo).
  //  NO dibuja el crosshair — este vive en el canvas superpuesto.
  //  Se invoca al cambiar datos, zoom, scroll o resize.
  // ============================================================

  render() {
    if (!this.market) return;
    const t0 = performance.now();

    const win   = this.compute_window();
    const sizeP = this._fit_canvas(this.els.priceCanvas);
    const plotW = sizeP.w - PRICE_AXIS_W;
    const barW  = plotW / win.count;
    this._lastBarW = barW;

    // Render normal, sin LOD: conserva la semántica original de index_to_x()
    // usada por PricePanel, ATRPanel, overlays y eje temporal.
    const candles = this.market.candles.slice(win.first, win.last + 1);

    let yMin, yMax;
    if (this.price_auto) {
      const yr = this.pricePanel.get_y_range(candles);
      yMin = yr.min; yMax = yr.max;
    } else {
      yMin = this.price_min;
      yMax = this.price_max;
    }

    this.priceScale.set_size(sizeP.w, sizeP.h, plotW);
    this.priceScale.set_x_window(win.virtualFirst, barW);
    this.priceScale.set_y_range(yMin, yMax);

    this.pricePanel.render(candles, win.first);
    this._draw_overlays(this.els.priceCanvas.getContext("2d"), win);
    this._draw_manual_fibs(this.els.priceCanvas.getContext("2d"), win);

    const lastC = this.market.candles[this.market.candles.length - 1];
    if (lastC) this.pricePanel.draw_last_price(lastC.close, lastC.open);

    // Panel ATR
    const sizeA    = this._fit_canvas(this.els.atrCanvas);
    const plotH    = sizeA.h - TIME_AXIS_H;
    const atrSlice = this.market.atr.slice(win.first, win.last + 1);
    const yrA = this.atr_auto
      ? this.atrPanel.get_y_range(atrSlice)
      : { min: this.atr_min, max: this.atr_max };

    this.atrScale.set_size(sizeA.w, plotH, plotW);
    this.atrScale.set_x_window(win.virtualFirst, barW);
    this.atrScale.set_y_range(yrA.min, yrA.max);
    this.atrPanel.render(atrSlice, win.first);

    const lastATR = this.market.atr[this.market.atr.length - 1];
    if (lastATR != null) this.atrPanel.draw_last_atr(lastATR);

    this.pricePanel.draw_time_axis(
      this.els.atrCanvas.getContext("2d"),
      this.market.candles, win.first, win.last, win.count, plotH + 2,
      this.market.timeframe
    );

    this._update_statusbar();

    // Si existen canvas superpuestos, el crosshair vive ahí.
    // Si el resto del repositorio todavía no los pasa en `els`, se usa el
    // comportamiento original y se dibuja sobre los canvas base.
    if (this._has_crosshair_layers()) {
      if (this._mouse) {
        this._hoverIndex = this.priceScale.x_to_index(this._mouse.x);
        this._draw_crosshair_only();
      } else {
        this._clear_crosshair();
      }
    } else {
      this._draw_crosshair_all();
      this._update_hover_status();
    }

    const dt = performance.now() - t0;
    if (dt > 20) {
      console.debug(`[render] ${dt.toFixed(1)}ms | bars=${win.count} barW=${barW.toFixed(2)}`);
    }
    this._notify_view_change(win);
  }

  // ============================================================
  //  LOD: cuando bar_width < 1, agrupa velas por pixel para que
  //  el render dibuje pocos elementos en lugar de miles.
  // ============================================================

  _get_render_candles(win, barW) {
    // Conservado por compatibilidad si otro código lo llama, pero no usado
    // por render(). El downsampling anterior rompía la correspondencia
    // índice ↔ pixel porque PricePanel dibuja cada candle como firstIndex + k.
    return {
      candles: this.market.candles.slice(win.first, win.last + 1),
      firstIndex: win.first,
    };
  }

  // ============================================================
  //  Crosshair en canvas superpuesto.
  //  Solo limpia/redibuja ese canvas; el canvas base no se toca.
  // ============================================================

  _has_crosshair_layers() {
    return !!(this.els.priceCrosshair && this.els.atrCrosshair);
  }

  _fit_xhair(xhairCanvas, baseCanvas) {
    const dpr  = window.devicePixelRatio || 1;
    const rect = baseCanvas.getBoundingClientRect();
    const w    = Math.max(1, Math.floor(rect.width));
    const h    = Math.max(1, Math.floor(rect.height));
    if (xhairCanvas.width !== w * dpr || xhairCanvas.height !== h * dpr) {
      xhairCanvas.width  = w * dpr;
      xhairCanvas.height = h * dpr;
    }
    const ctx = xhairCanvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    return ctx;
  }

  _clear_crosshair() {
    const dpr = window.devicePixelRatio || 1;
    for (const cv of [this.els.priceCrosshair, this.els.atrCrosshair]) {
      if (!cv) continue;
      const ctx = cv.getContext("2d");
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, cv.width, cv.height);
    }
  }

  _draw_crosshair_only() {
    if (!this._mouse || this._hoverIndex === null) return;
    const win = this.compute_window();
    if (this._hoverIndex < win.first || this._hoverIndex > win.last) return;
    const cx = this.priceScale.index_to_center_x(this._hoverIndex);
    if (cx < 0 || cx > this.priceScale.plot_width) return;

    const pCtx = this._fit_xhair(this.els.priceCrosshair, this.els.priceCanvas);
    const aCtx = this._fit_xhair(this.els.atrCrosshair,   this.els.atrCanvas);

    this._draw_vline(pCtx, cx, this.priceScale.height);
    this._draw_vline(aCtx, cx, this.atrScale.height);

    if (this._mouse.panel === "price") {
      const price    = this.priceScale.y_to_value(this._mouse.y);
      const snapped  = Math.ceil(price * 4 - 1e-9) / 4;
      const snappedY = this.priceScale.value_to_y(snapped);
      this._draw_hline(pCtx, snappedY, this.priceScale.plot_width);
      this._draw_y_label(pCtx, snappedY, this.priceScale, snapped.toFixed(2));
    } else {
      this._draw_hline(aCtx, this._mouse.y, this.atrScale.plot_width);
      const atrVal = this.atrScale.y_to_value(this._mouse.y);
      this._draw_y_label(aCtx, this._mouse.y, this.atrScale, atrVal.toFixed(2));
    }

    const c = this.market.candles[this._hoverIndex];
    if (c) {
      const label = `${diaSemana(c.time)} ${c.time.slice(5, 10)} ${c.time.slice(11, 16)}`;
      this._draw_x_label(aCtx, cx, label);
    }

    this._update_hover_status();
  }

  // ============================================================
  //  Eventos de raton
  // ============================================================

  _enter_manual_mode() {
    if (this.price_auto) {
      this.price_auto = false;
      this.price_min  = this.priceScale.min_value;
      this.price_max  = this.priceScale.max_value;
    }
  }

  _enter_manual_atr_mode() {
    if (this.atr_auto) {
      this.atr_auto = false;
      this.atr_min  = this.atrScale.min_value;
      this.atr_max  = this.atrScale.max_value;
    }
  }

  _anchor_from_mouse_event(e) {
    if (!this.market?.candles?.length) return null;
    const rect = this.els.priceCanvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    let idx = Math.round(this.priceScale.x_to_index_float(x) - 0.5);
    if (idx < 0) idx = 0;
    if (idx >= this.market.candles.length) idx = this.market.candles.length - 1;
    const candle = this.market.candles[idx];
    const absIndex = candle?.abs_index ?? ((this.market.win_start ?? 0) + idx);
    return {
      index: idx,
      abs_index: absIndex,
      time: candle?.time,
      price: this.priceScale.y_to_value(y),
    };
  }

  _handle_fib_click(e) {
    const anchor = this._anchor_from_mouse_event(e);
    if (!anchor) return;

    if (!this._fibAnchor) {
      this._fibAnchor = anchor;
      this._fibHoverAnchor = anchor;
      this.request_render();
      return;
    }

    if (this._fibAnchor.abs_index === anchor.abs_index &&
        Math.abs(this._fibAnchor.price - anchor.price) < 1e-9) {
      return;
    }

    this.manual_fibs.push({
      id: `MFIB_${Date.now()}_${this.manual_fibs.length}`,
      timeframe: this.market.timeframe,
      a: this._fibAnchor,
      b: anchor,
    });
    this._fibAnchor = null;
    this._fibHoverAnchor = null;
    this.request_render();
  }

  bind_events() {
    const btnAuto   = document.getElementById("btn-auto");
    const btnManual = document.getElementById("btn-manual");
    if (btnAuto && btnManual) {
      const syncBtns = () => {
        btnAuto  .classList.toggle("active", this.mode === "auto");
        btnManual.classList.toggle("active", this.mode === "manual");
      };
      btnAuto  .addEventListener("click", () => { this.set_mode("auto");   syncBtns(); });
      btnManual.addEventListener("click", () => { this.set_mode("manual"); syncBtns(); });
    }

    const cvs = [this.els.priceCanvas, this.els.atrCanvas];
    this.els.priceCanvas.addEventListener("mousedown", (e) => this._on_mouse_down(e, "price"));
    this.els.atrCanvas.addEventListener("mousedown",   (e) => this._on_mouse_down(e, "atr"));
    this.els.priceCanvas.addEventListener("wheel", (e) => this._on_wheel(e, "price"), { passive: false });
    this.els.atrCanvas.addEventListener("wheel",   (e) => this._on_wheel(e, "atr"),   { passive: false });
    for (const cv of cvs) {
      cv.addEventListener("contextmenu", (e) => e.preventDefault());
      cv.addEventListener("mousemove",  (e) => this._on_canvas_move(e, cv));
      cv.addEventListener("mouseleave", ()  => this._on_canvas_leave());
    }
    window.addEventListener("mousemove", (e) => this._on_mouse_move(e));
    window.addEventListener("mouseup",   (e) => this._on_mouse_up(e));
  }

  _on_mouse_down(e, panel) {
    if (panel === "price" && this.active_tool === "fib" && e.button === 0) {
      e.preventDefault();
      this._handle_fib_click(e);
      return;
    }
    if (e.button === 0) {
      this._dragX = true; this._startX = e.clientX; this._startOff = this.offset;
      if (this.mode === "manual") {
        this._dragYPanel = panel;
        this._dragY = true; this._startY = e.clientY;
        if (panel === "atr") {
          this._enter_manual_atr_mode();
          this._startPMin = this.atr_min; this._startPMax = this.atr_max;
        } else {
          this._enter_manual_mode();
          this._startPMin = this.price_min; this._startPMax = this.price_max;
        }
      }
    } else if (e.button === 2) {
      e.preventDefault();
    }
  }

  // mousemove sobre el canvas: actualiza posicion y redibuja SOLO el crosshair.
  // El render completo NO se llama aqui — de eso se encarga el canvas superpuesto.
  _on_canvas_move(e, cv) {
    if (e.ctrlKey) return;
    const rect  = cv.getBoundingClientRect();
    const panel = (cv === this.els.priceCanvas) ? "price" : "atr";
    this._mouse      = { x: e.clientX - rect.left, y: e.clientY - rect.top, panel };
    this._hoverIndex = this.priceScale.x_to_index(this._mouse.x);

    if (panel === "price" && this.active_tool === "fib" && this._fibAnchor) {
      this._fibHoverAnchor = this._anchor_from_mouse_event(e);
      this.request_render();
      return;
    }

    if (this._has_crosshair_layers()) {
      this._draw_crosshair_only();
    } else {
      this.request_render();
    }
  }

  _on_canvas_leave() {
    this._mouse      = null;
    this._hoverIndex = null;

    if (this._has_crosshair_layers()) {
      this._clear_crosshair();
      if (this.els.statusHover) {
        this.els.statusHover.textContent = "Mueve el cursor sobre el grafico...";
      }
    } else {
      this.request_render();
    }
  }

  // mousemove global: solo para drag (scroll/pan y zoom vertical manual)
  _on_mouse_move(e) {
    if (this._dragX) {
      const dxBars = (e.clientX - this._startX) / this._lastBarW;
      this.offset  = Math.round(this._startOff + dxBars);
      this._clamp_offset();
      this.request_render();
    }
    if (this._dragY) {
      const range  = this._startPMax - this._startPMin;
      const scaleH = this._dragYPanel === "atr" ? this.atrScale.height : this.priceScale.height;
      const shift  = (e.clientY - this._startY) / (scaleH || 1) * range;
      if (this._dragYPanel === "atr") {
        this.atr_min = this._startPMin + shift;
        this.atr_max = this._startPMax + shift;
      } else {
        this.price_min = this._startPMin + shift;
        this.price_max = this._startPMax + shift;
      }
      this.request_render();
    }
  }

  _on_mouse_up(e) { this._dragX = false; this._dragY = false; }

  _on_wheel(e, panel) {
    e.preventDefault();
    const rect   = e.currentTarget.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    if (e.shiftKey || mouseX > this.priceScale.plot_width) {
      if (panel === "atr") this._vertical_zoom_atr(e.deltaY);
      else                 this._vertical_zoom(e.deltaY);
    } else if (e.ctrlKey) {
      this._zoom_at_cursor(e.deltaY, mouseX);
    } else {
      this._horizontal_zoom(e.deltaY, mouseX);
    }
  }

  _horizontal_zoom(delta, mouseX) {
    const win      = this.compute_window();
    const prevBars = this.visible_bars;
    const factor   = delta > 0 ? 1.6 : 1 / 1.6;

    this.visible_bars = factor < 1
      ? Math.floor(this.visible_bars * factor)
      : Math.ceil(this.visible_bars * factor);

    this._clamp_bars();

    if (this.mode === "auto") {
      // Comportamiento correcto del commit 0f638fc:
      // en auto se mantiene fija la última vela real.
      this.offset = Math.max(0, this.offset);
    } else if (this.visible_bars !== prevBars) {
      // En manual, el zoom horizontal se ancla al cursor.
      const idxUnderCursor = win.virtualFirst + mouseX / this._lastBarW;
      const plotW  = this.priceScale.plot_width ||
                     (this.els.priceCanvas.getBoundingClientRect().width - PRICE_AXIS_W);
      const n      = this.market.candles.length;
      const count  = Math.min(this.visible_bars, n);
      const newBarW  = plotW / count;
      const newFirst = idxUnderCursor - mouseX / newBarW;
      this.offset = Math.round((n - 1) - count + 1 - newFirst);
    }

    this._clamp_offset();
    this.request_render();
  }

  _zoom_at_cursor(delta, mouseX) {
    const win      = this.compute_window();
    const prevBars = this.visible_bars;
    const factor   = delta > 0 ? 2.0 : 1 / 2.0;

    this.visible_bars = factor < 1
      ? Math.floor(this.visible_bars * factor)
      : Math.ceil(this.visible_bars * factor);

    this._clamp_bars();

    if (this.visible_bars !== prevBars) {
      const idxUnderCursor = win.virtualFirst + mouseX / this._lastBarW;
      const plotW  = this.priceScale.plot_width ||
                     (this.els.priceCanvas.getBoundingClientRect().width - PRICE_AXIS_W);
      const n      = this.market.candles.length;
      const count  = Math.min(this.visible_bars, n);
      const newBarW  = plotW / count;
      const newFirst = idxUnderCursor - mouseX / newBarW;

      this.offset = Math.round((n - 1) - count + 1 - newFirst);

      // Permite espacios vacíos antes/después, pero evita que todo el gráfico
      // quede fuera por encima del último histórico real.
      const maxOff = Math.max(0, n - 2);
      if (this.offset > maxOff) this.offset = maxOff;
    }

    this.request_render();
  }

  _vertical_zoom(delta) {
    this._enter_manual_mode();
    const center = (this.price_min + this.price_max) / 2;
    const half   = (this.price_max - this.price_min) / 2;
    const factor = delta > 0 ? 1.1 : 1 / 1.1;
    this.price_min = center - half * factor;
    this.price_max = center + half * factor;
    this.request_render();
  }

  _vertical_zoom_atr(delta) {
    this._enter_manual_atr_mode();
    const center = (this.atr_min + this.atr_max) / 2;
    const half   = (this.atr_max - this.atr_min) / 2;
    const factor = delta > 0 ? 1.1 : 1 / 1.1;
    this.atr_min = center - half * factor;
    this.atr_max = center + half * factor;
    this.request_render();
  }

  _draw_crosshair_all() {
    if (!this._mouse || this._hoverIndex === null) return;

    const win = this.compute_window();
    if (this._hoverIndex < win.first || this._hoverIndex > win.last) return;

    const cx = this.priceScale.index_to_center_x(this._hoverIndex);
    if (cx < 0 || cx > this.priceScale.plot_width) return;

    const priceCtx = this.els.priceCanvas.getContext("2d");
    const atrCtx   = this.els.atrCanvas.getContext("2d");

    this._draw_vline(priceCtx, cx, this.priceScale.height);
    this._draw_vline(atrCtx,   cx, this.atrScale.height);

    if (this._mouse.panel === "price") {
      const price    = this.priceScale.y_to_value(this._mouse.y);
      const snapped  = Math.ceil(price * 4 - 1e-9) / 4;
      const snappedY = this.priceScale.value_to_y(snapped);
      this._draw_hline(priceCtx, snappedY, this.priceScale.plot_width);
      this._draw_y_label(priceCtx, snappedY, this.priceScale, snapped.toFixed(2));
    } else {
      this._draw_hline(atrCtx, this._mouse.y, this.atrScale.plot_width);
      const atrVal = this.atrScale.y_to_value(this._mouse.y);
      this._draw_y_label(atrCtx, this._mouse.y, this.atrScale, atrVal.toFixed(2));
    }

    const c = this.market.candles[this._hoverIndex];
    if (c) {
      const label = `${diaSemana(c.time)} ${c.time.slice(5, 10)} ${c.time.slice(11, 16)}`;
      this._draw_x_label(atrCtx, cx, label);
    }
  }

  // ============================================================
  //  Dibujado de primitivas para el crosshair
  // ============================================================

  _draw_y_label(ctx, y, scale, label) {
    const x = scale.plot_width;
    const w = scale.width - x;
    if (w <= 2) return;
    const h = 16;
    ctx.save();
    ctx.fillStyle = "#758696";
    ctx.fillRect(x, Math.round(y) - h / 2, w, h);
    ctx.fillStyle = "#fff";
    ctx.font = "11px -apple-system, Arial, sans-serif";
    ctx.textBaseline = "middle";
    ctx.textAlign    = "left";
    ctx.fillText(label, x + 4, Math.round(y));
    ctx.restore();
  }

  _draw_x_label(ctx, x, label) {
    const w     = 104;
    const h     = TIME_AXIS_H - 2;
    const plotH = this.atrScale.height;
    if (x < w / 2 || x > this.atrScale.plot_width - w / 2) return;
    ctx.save();
    ctx.fillStyle = "#758696";
    ctx.fillRect(Math.round(x) - w / 2, plotH + 1, w, h);
    ctx.fillStyle = "#fff";
    ctx.font = "11px -apple-system, Arial, sans-serif";
    ctx.textBaseline = "middle";
    ctx.textAlign    = "center";
    ctx.fillText(label, Math.round(x), plotH + 1 + h / 2);
    ctx.restore();
  }

  _draw_vline(ctx, x, h) {
    ctx.save();
    ctx.strokeStyle = "#758696"; ctx.lineWidth = 1; ctx.setLineDash([4, 4]);
    ctx.beginPath(); ctx.moveTo(Math.round(x) + 0.5, 0); ctx.lineTo(Math.round(x) + 0.5, h);
    ctx.stroke(); ctx.restore();
  }

  _draw_hline(ctx, y, w) {
    ctx.save();
    ctx.strokeStyle = "#758696"; ctx.lineWidth = 1; ctx.setLineDash([4, 4]);
    ctx.beginPath(); ctx.moveTo(0, Math.round(y) + 0.5); ctx.lineTo(w, Math.round(y) + 0.5);
    ctx.stroke(); ctx.restore();
  }

  // ============================================================
  //  Statusbar
  // ============================================================

  _update_statusbar() {
    const win = this.compute_window();
    if (this.els.statusWindow) {
      const mr  = this.overlays?.market_regime;
      const reg = mr ? ` | ${mr.state} (${mr.confidence_score})` : '';
      this.els.statusWindow.textContent =
        `TF ${this.market.timeframe} | ${this.mode} | barras ${win.count} | offset ${this.offset}${reg}`;
    }
  }

  _update_hover_status() {
    if (!this.els.statusHover) return;

    if (this._hoverIndex !== null &&
        this._hoverIndex >= 0 && this._hoverIndex < this.market.candles.length) {
      const c      = this.market.candles[this._hoverIndex];
      const a      = this.market.atr[this._hoverIndex];
      const atrTxt = (a == null) ? "-" : a.toFixed(2);
      const dow    = diaSemana(c.time);
      const fecha  = c.time.slice(0, 10);
      const hora   = c.time.slice(11, 16);
      const volTxt = c.volume != null ? c.volume.toLocaleString() : "-";

      this.els.statusHover.textContent =
        `${dow} ${fecha} ${hora}  O:${c.open} H:${c.high} L:${c.low} C:${c.close}  Vol:${volTxt}  ATR:${atrTxt}`;
    } else {
      this.els.statusHover.textContent = "Mueve el cursor sobre el grafico...";
    }
  }

  // ============================================================
  //  Filtro de capas visuales.
  //  La categoria se decide por source_type y color_role, que ya vienen
  //  generados por Market::Overlays::* en el backend.
  // ============================================================

  _overlay_layer_on(key) {
    return this.overlay_visibility?.[key] !== false;
  }

  _is_overlay_shape_visible(sh) {
    const src  = (sh.source_type || '').toLowerCase();
    const role = (sh.color_role  || '').toLowerCase();

    const isSmcShape = src === 'smc' || src === 'fvg' || src === 'fib' ||
                       role.startsWith('pivot_') || role.startsWith('bos_') ||
                       role.startsWith('choch_') || role.startsWith('fvg_') ||
                       role === 'fib_level';
    if (isSmcShape && !this._overlay_layer_on('smc_all')) return false;

    if (role === 'pivot_hh') return this._overlay_layer_on('smc_hh');
    if (role === 'pivot_hl') return this._overlay_layer_on('smc_hl');
    if (role === 'pivot_lh') return this._overlay_layer_on('smc_lh');
    if (role === 'pivot_ll') return this._overlay_layer_on('smc_ll');
    if (role.startsWith('bos_'))   return this._overlay_layer_on('smc_bos');
    if (role.startsWith('choch_')) return this._overlay_layer_on('smc_choch');
    if (src === 'fvg' || role.startsWith('fvg_')) return this._overlay_layer_on('smc_fvg');
    if (src === 'fib' || role === 'fib_level')    return this._overlay_layer_on('smc_fib');

    if (src === 'liquidity' && !this._overlay_layer_on('liq_all')) return false;
    if ((sh.htf_source || sh.internal_or_external === 'external') && !this._overlay_layer_on('liq_htf')) return false;

    if (role === 'bsl') return this._overlay_layer_on('liq_bsl');
    if (role === 'ssl') return this._overlay_layer_on('liq_ssl');
    if (role === 'eqh') return this._overlay_layer_on('liq_eqh');
    if (role === 'eql') return this._overlay_layer_on('liq_eql');
    if (role === 'grab') return this._overlay_layer_on('liq_grab');
    if (role === 'sweep_up' || role === 'sweep_down') return this._overlay_layer_on('liq_sweep');
    if (role === 'run') return this._overlay_layer_on('liq_run');

    return true;
  }

  _shape_index_from_anchor(sh, absKey, timeKey, localKey) {
    const rawAbs = sh[absKey];
    if (rawAbs !== undefined && rawAbs !== null && rawAbs !== '') {
      const abs = Number(rawAbs);
      if (Number.isFinite(abs)) {
        if (this._absToLocal.has(abs)) return this._absToLocal.get(abs);
        return abs - (this.market?.win_start ?? 0);
      }
    }

    const time = sh[timeKey];
    if (time && this._timeToLocal.has(time)) return this._timeToLocal.get(time);

    return sh[localKey] ?? 0;
  }

  _shape_with_local_indices(sh) {
    const x1 = this._shape_index_from_anchor(sh, 'x1_abs_index', 'x1_time', 'x1_index');
    const x2 = this._shape_index_from_anchor(sh, 'x2_abs_index', 'x2_time', 'x2_index');
    return {
      ...sh,
      x1_index: x1,
      x2_index: x2 ?? x1,
    };
  }

  // ============================================================
  //  Overlays (shapes de Liquidity + SMC)
  // ============================================================

  _draw_overlays(ctx, win) {
    if (!this.overlays) return;
    const s       = this.priceScale;
    const lshapes = this.overlays.liquidity?.overlay_shapes ?? [];
    const sshapes = this.overlays.smc?.overlay_shapes       ?? [];

    const rects  = [];
    const lines  = [];
    const labels = [];
    let htfLabelCount = 0;

    for (const sh of [...lshapes, ...sshapes]) {
      if (!sh.visible_by_default) continue;
      if (!this._is_overlay_shape_visible(sh)) continue;
      const localShape = this._shape_with_local_indices(sh);
      if ((localShape.x2_index ?? localShape.x1_index) < win.first) continue;
      if (localShape.x1_index > win.last) continue;
      if      (localShape.kind === 'rectangle')                rects.push(localShape);
      else if (localShape.kind === 'line' || localShape.kind === 'fib_line') lines.push(localShape);
      else {
        if (localShape.htf_source) {
          if (htfLabelCount >= MAX_HTF_LABELS) continue;
          htfLabelCount++;
        }
        labels.push(localShape);
      }
    }

    for (const sh of rects)  this._ov_rect(ctx, s, sh, win);
    for (const sh of lines)  this._ov_line(ctx, s, sh, win);
    for (const sh of labels) this._ov_label(ctx, s, sh, win);

    this._draw_regime_badge(ctx);
  }

  _draw_regime_badge(ctx) {
    if (!this._overlay_layer_on('market_regime')) return;
    const mr = this.overlays?.market_regime;
    if (!mr || !mr.state) return;
    const s     = this.priceScale;
    const color = REGIME_COLORS[mr.state] ?? '#546E7A';
    const label = mr.state;
    const score = mr.confidence_score ? ` ${mr.confidence_score}` : '';

    ctx.save();
    ctx.font = 'bold 11px Arial';
    const tw = ctx.measureText(label).width;
    const pw = tw + 16;
    const ph = 18;
    const px = s.plot_width - pw - 6;
    const py = 6;

    ctx.globalAlpha = 0.90;
    ctx.fillStyle   = color;
    ctx.fillRect(px, py, pw, ph);

    ctx.globalAlpha  = 1.0;
    ctx.fillStyle    = '#ffffff';
    ctx.textBaseline = 'middle';
    ctx.textAlign    = 'center';
    ctx.fillText(label, px + pw / 2, py + ph / 2);

    if (score) {
      ctx.globalAlpha = 0.80;
      ctx.font        = '9px Arial';
      ctx.fillStyle   = color;
      ctx.fillText(score, px + pw / 2, py + ph + 7);
    }
    ctx.restore();
  }

  _ov_rect(ctx, s, sh, win) {
    const color = OV_COLORS[sh.color_role] ?? '#888888';
    const x1    = Math.max(sh.x1_index, win.first - 1);
    const x2    = Math.min(sh.x2_index, win.last  + 1);
    const px1   = s.index_to_x(x1);
    const px2   = s.index_to_x(x2) + s.bar_width;
    const pyTop = s.value_to_y(sh.y2_price);
    const pyBot = s.value_to_y(sh.y1_price);
    if (pyTop > s.height || pyBot < 0) return;
    ctx.save();
    ctx.globalAlpha = sh.opacity ?? 0.3;
    ctx.fillStyle   = color;
    ctx.fillRect(px1, pyTop, px2 - px1, pyBot - pyTop);
    if (sh.text) {
      ctx.globalAlpha  = Math.min(1.0, (sh.opacity ?? 0.3) + 0.45);
      ctx.font         = '9px Arial';
      ctx.textBaseline = 'top';
      ctx.textAlign    = 'left';
      ctx.fillText(sh.text, px1 + 2, pyTop + 2);
    }
    ctx.restore();
  }

  _ov_line(ctx, s, sh, win) {
    const color = OV_COLORS[sh.color_role] ?? '#888888';
    const x1    = Math.max(sh.x1_index, win.first - 1);
    const x2    = Math.min(sh.x2_index ?? sh.x1_index, win.last + 1);
    const px1   = s.index_to_center_x(x1);
    const px2   = s.index_to_center_x(x2);
    const py    = s.value_to_y(sh.y1_price);
    if (py < 0 || py > s.height) return;
    ctx.save();
    ctx.globalAlpha = sh.opacity ?? 0.8;
    ctx.strokeStyle = color;
    ctx.lineWidth   = sh.kind === 'fib_line' ? 0.8 : 1;
    ctx.setLineDash(_ov_dash(sh.line_style));
    ctx.beginPath();
    ctx.moveTo(px1, Math.round(py) + 0.5);
    ctx.lineTo(px2, Math.round(py) + 0.5);
    ctx.stroke();
    if (sh.kind === 'fib_line' && sh.text) {
      ctx.setLineDash([]);
      ctx.globalAlpha  = 0.75;
      ctx.fillStyle    = color;
      ctx.font         = '9px Arial';
      ctx.textBaseline = 'bottom';
      ctx.textAlign    = 'right';
      ctx.fillText(sh.text, px2 - 2, Math.round(py) - 1);
    }
    ctx.restore();
  }

  _ov_label(ctx, s, sh, win) {
    if (sh.x1_index < win.first || sh.x1_index > win.last) return;
    const color = OV_COLORS[sh.color_role] ?? '#888888';
    const px    = s.index_to_center_x(sh.x1_index);
    const py    = s.value_to_y(sh.y1_price);
    if (py < 0 || py > s.height) return;
    const text = sh.text ?? '';
    if (!text) return;
    ctx.save();
    ctx.globalAlpha  = sh.opacity ?? 0.9;
    ctx.fillStyle    = color;
    ctx.font         = '10px Arial';
    ctx.textBaseline = 'bottom';
    ctx.textAlign    = 'center';
    ctx.fillText(text, px, py - 3);
    ctx.restore();
  }

  _manual_anchor_to_local(anchor) {
    if (!anchor) return null;
    if (this._absToLocal.has(anchor.abs_index)) {
      return { ...anchor, index: this._absToLocal.get(anchor.abs_index) };
    }
    return {
      ...anchor,
      index: anchor.abs_index - (this.market?.win_start ?? 0),
    };
  }

  _draw_manual_fibs(ctx, win) {
    const tf = this.market?.timeframe;
    if (!tf) return;

    for (const fib of this.manual_fibs) {
      if (fib.timeframe !== tf) continue;
      this._draw_manual_fib(ctx, win, fib, false);
    }

    if (this._fibAnchor && this._fibHoverAnchor) {
      this._draw_manual_fib(ctx, win, {
        timeframe: tf,
        a: this._fibAnchor,
        b: this._fibHoverAnchor,
      }, true);
    }
  }

  _draw_manual_fib(ctx, win, fib, preview) {
    const a = this._manual_anchor_to_local(fib.a);
    const b = this._manual_anchor_to_local(fib.b);
    if (!a || !b) return;

    const s = this.priceScale;
    const xMin = Math.min(a.index, b.index);
    const xMax = Math.max(a.index, b.index);
    if (xMin > win.last + 1) return;

    const drawStart = Math.max(Math.min(xMin, win.last), win.first - 1);
    const drawEnd = Math.min(win.last + 1, Math.max(xMax, win.last + 1));
    const px1 = s.index_to_center_x(drawStart);
    const px2 = s.index_to_center_x(drawEnd);
    const guideAVisible = a.index >= win.first - 2 && a.index <= win.last + 2;
    const guideBVisible = b.index >= win.first - 2 && b.index <= win.last + 2;

    ctx.save();
    ctx.globalAlpha = preview ? 0.55 : 0.86;
    ctx.strokeStyle = preview ? '#90A4AE' : '#B9C8E8';
    ctx.fillStyle = preview ? '#B0BEC5' : '#D7E3FF';
    ctx.lineWidth = preview ? 1 : 1.15;

    if (guideAVisible || guideBVisible) {
      ctx.setLineDash([4, 3]);
      ctx.beginPath();
      ctx.moveTo(s.index_to_center_x(a.index), s.value_to_y(a.price));
      ctx.lineTo(s.index_to_center_x(b.index), s.value_to_y(b.price));
      ctx.stroke();
      ctx.setLineDash([]);
    }

    for (const ratio of MANUAL_FIB_LEVELS) {
      const price = a.price + (b.price - a.price) * ratio;
      const py = s.value_to_y(price);
      if (py < -12 || py > s.height + 12) continue;
      ctx.globalAlpha = preview ? 0.45 : (ratio === 0 || ratio === 1 ? 0.82 : 0.68);
      ctx.strokeStyle = ratio === 0.5 ? '#FFD166' : '#9BB7E5';
      ctx.beginPath();
      ctx.moveTo(px1, Math.round(py) + 0.5);
      ctx.lineTo(px2, Math.round(py) + 0.5);
      ctx.stroke();

      if (!preview && px2 > 24) {
        ctx.globalAlpha = 0.92;
        ctx.fillStyle = ratio === 0.5 ? '#FFD166' : '#D7E3FF';
        ctx.font = '10px Arial';
        ctx.textBaseline = 'middle';
        ctx.textAlign = 'right';
        ctx.fillText(`${(ratio * 100).toFixed(ratio === 0 || ratio === 1 ? 0 : 1)}% ${price.toFixed(2)}`,
          Math.min(px2 - 4, s.plot_width - 4), Math.round(py));
      }
    }

    for (const anchor of [a, b]) {
      const px = s.index_to_center_x(anchor.index);
      const py = s.value_to_y(anchor.price);
      if (px < -8 || px > s.plot_width + 8 || py < -8 || py > s.height + 8) continue;
      ctx.globalAlpha = preview ? 0.70 : 0.95;
      ctx.fillStyle = '#131722';
      ctx.strokeStyle = '#D7E3FF';
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      ctx.arc(px, py, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
    }

    ctx.restore();
  }

  reset_view() {
    this.visible_bars = 120;
    this.offset       = 0;
    this.price_auto   = true;
    this.atr_auto     = true;
    this.request_render();
  }
}
