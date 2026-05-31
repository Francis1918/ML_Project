"use strict";

// Dia de la semana (lun..dom) de una fecha ISO, sin influencia de la zona horaria.
function diaSemana(iso) {
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return "";
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).getUTCDay();
  return ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"][d];
}

const PRICE_AXIS_W = 60;
const TIME_AXIS_H  = 20;
const MIN_BARS = 20;
const MAX_BARS = 1500;

class ChartEngine {
  constructor(market, els) {
    this.market = market;
    this.els    = els;
    this.visible_bars = 120;
    this.offset       = 0;
    this.price_auto = true;
    this.price_min  = null;
    this.price_max  = null;
    this._dragX = false; this._dragY = false;
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
  }
  set_market(market) { this.market = market; }
  round(v) { return Math.round(v); }
  request_render() {
    if (this._renderPending) return;
    this._renderPending = true;
    requestAnimationFrame(() => { this._renderPending = false; this.render(); });
  }
  compute_window() {
    const n = this.market.candles.length;
    const count = Math.min(this.visible_bars, n);
    let last = n - 1 - this.offset;
    let first = last - count + 1;
    if (last > n - 1) last = n - 1;
    if (first < 0) first = 0;
    return { first, last, count: last - first + 1 };
  }
  _clamp_offset() {
    const n = this.market.candles.length;
    const maxOff = Math.max(0, n - this.visible_bars);
    if (this.offset < 0) this.offset = 0;
    if (this.offset > maxOff) this.offset = maxOff;
  }
  _clamp_bars() {
    const n = this.market.candles.length;
    const top = Math.min(MAX_BARS, n);
    if (this.visible_bars < MIN_BARS) this.visible_bars = MIN_BARS;
    if (this.visible_bars > top) this.visible_bars = top;
  }
  _fit_canvas(canvas) {
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
      canvas.width = w * dpr; canvas.height = h * dpr;
    }
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);   // limpia TODO el canvas cada frame (evita acumulacion)
    return { w, h };
  }
  render() {
    const win = this.compute_window();
    const sizeP = this._fit_canvas(this.els.priceCanvas);
    const plotW = sizeP.w - PRICE_AXIS_W;
    const barW = plotW / win.count;
    this._lastBarW = barW;
    const candles = this.market.candles.slice(win.first, win.last + 1);
    let yMin, yMax;
    if (this.price_auto) {
      const yr = this.pricePanel.get_y_range(candles);
      yMin = yr.min; yMax = yr.max;
    } else { yMin = this.price_min; yMax = this.price_max; }
    this.priceScale.set_size(sizeP.w, sizeP.h, plotW);
    this.priceScale.set_x_window(win.first, barW);
    this.priceScale.set_y_range(yMin, yMax);
    this.pricePanel.render(candles, win.first);
    const sizeA = this._fit_canvas(this.els.atrCanvas);
    const plotH = sizeA.h - TIME_AXIS_H;
    const atrSlice = this.market.atr.slice(win.first, win.last + 1);
    const yrA = this.atrPanel.get_y_range(atrSlice);
    this.atrScale.set_size(sizeA.w, plotH, plotW);
    this.atrScale.set_x_window(win.first, barW);
    this.atrScale.set_y_range(yrA.min, yrA.max);
    this.atrPanel.render(atrSlice, win.first);
    this.pricePanel.draw_time_axis(
      this.els.atrCanvas.getContext("2d"),
      this.market.anchors, win.first, win.last, plotH + 2
    );
    this._draw_crosshair_all();
    this._update_statusbar();
  }
  _enter_manual_mode() {
    if (this.price_auto) {
      this.price_auto = false;
      this.price_min = this.priceScale.min_value;
      this.price_max = this.priceScale.max_value;
    }
  }
  bind_events() {
    const cvs = [this.els.priceCanvas, this.els.atrCanvas];
    this.els.priceCanvas.addEventListener("mousedown", (e) => this._on_mouse_down(e));
    this.els.atrCanvas.addEventListener("mousedown", (e) => this._on_mouse_down(e));
    for (const cv of cvs) {
      cv.addEventListener("wheel", (e) => this._on_wheel(e), { passive: false });
      cv.addEventListener("contextmenu", (e) => e.preventDefault());
      cv.addEventListener("mousemove", (e) => this._on_canvas_move(e, cv));
      cv.addEventListener("mouseleave", () => this._on_canvas_leave());
    }
    window.addEventListener("mousemove", (e) => this._on_mouse_move(e));
    window.addEventListener("mouseup", (e) => this._on_mouse_up(e));
  }
  _on_mouse_down(e) {
    if (e.button === 0) {
      this._dragX = true; this._startX = e.clientX; this._startOff = this.offset;
    } else if (e.button === 2) {
      e.preventDefault();
      this._enter_manual_mode();
      this._dragY = true; this._startY = e.clientY;
      this._startPMin = this.price_min; this._startPMax = this.price_max;
    }
  }
  _on_canvas_move(e, cv) {
    const rect = cv.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const panel = (cv === this.els.priceCanvas) ? "price" : "atr";
    this._mouse = { x, y, panel };
    this._hoverIndex = this.priceScale.x_to_index(x);
    this.request_render();
  }
  _on_canvas_leave() {
    this._mouse = null; this._hoverIndex = null;
    this.request_render();
  }
  _on_mouse_move(e) {
    if (this._dragX) {
      const dxBars = (e.clientX - this._startX) / this._lastBarW;
      this.offset = Math.round(this._startOff + dxBars);
      this._clamp_offset();
      this.request_render();
    }
    if (this._dragY) {
      const range = this._startPMax - this._startPMin;
      const dyFrac = (e.clientY - this._startY) / (this.priceScale.height || 1);
      const shift = dyFrac * range;
      this.price_min = this._startPMin + shift;
      this.price_max = this._startPMax + shift;
      this.request_render();
    }
  }
  _on_mouse_up(e) { this._dragX = false; this._dragY = false; }
  _on_wheel(e) {
    e.preventDefault();
    const rect = e.currentTarget.getBoundingClientRect();
    if (e.shiftKey) { this._vertical_zoom(e.deltaY); }
    else { this._horizontal_zoom(e.deltaY, e.clientX - rect.left); }
  }
  _horizontal_zoom(delta, mouseX) {
    const win = this.compute_window();
    const idxUnderCursor = win.first + mouseX / this._lastBarW;
    const factor = delta > 0 ? 1.1 : 1 / 1.1;
    this.visible_bars = Math.round(this.visible_bars * factor);
    this._clamp_bars();
    const plotW = this.priceScale.plot_width ||
                  (this.els.priceCanvas.getBoundingClientRect().width - PRICE_AXIS_W);
    const newBarW = plotW / Math.min(this.visible_bars, this.market.candles.length);
    const newFirst = idxUnderCursor - mouseX / newBarW;
    const n = this.market.candles.length;
    const count = Math.min(this.visible_bars, n);
    this.offset = Math.round((n - 1) - count + 1 - newFirst);
    this._clamp_offset();
    this.request_render();
  }
  _vertical_zoom(delta) {
    this._enter_manual_mode();
    const center = (this.price_min + this.price_max) / 2;
    const half = (this.price_max - this.price_min) / 2;
    const factor = delta > 0 ? 1.1 : 1 / 1.1;
    this.price_min = center - half * factor;
    this.price_max = center + half * factor;
    this.request_render();
  }
  _draw_crosshair_all() {
    if (!this._mouse || this._hoverIndex === null) return;
    const win = this.compute_window();
    if (this._hoverIndex < win.first || this._hoverIndex > win.last) return;
    const cx = this.priceScale.index_to_center_x(this._hoverIndex);
    if (cx < 0 || cx > this.priceScale.plot_width) return;
    this._draw_vline(this.els.priceCanvas.getContext("2d"), cx, this.priceScale.height);
    this._draw_vline(this.els.atrCanvas.getContext("2d"), cx, this.atrScale.height);
    if (this._mouse.panel === "price") {
      this._draw_hline(this.els.priceCanvas.getContext("2d"), this._mouse.y, this.priceScale.plot_width);
    } else {
      this._draw_hline(this.els.atrCanvas.getContext("2d"), this._mouse.y, this.atrScale.plot_width);
    }
  }
  _draw_vline(ctx, x, h) {
    ctx.save(); ctx.strokeStyle = "#758696"; ctx.lineWidth = 1; ctx.setLineDash([4, 4]);
    ctx.beginPath(); ctx.moveTo(Math.round(x) + 0.5, 0); ctx.lineTo(Math.round(x) + 0.5, h);
    ctx.stroke(); ctx.restore();
  }
  _draw_hline(ctx, y, w) {
    ctx.save(); ctx.strokeStyle = "#758696"; ctx.lineWidth = 1; ctx.setLineDash([4, 4]);
    ctx.beginPath(); ctx.moveTo(0, Math.round(y) + 0.5); ctx.lineTo(w, Math.round(y) + 0.5);
    ctx.stroke(); ctx.restore();
  }
  _update_statusbar() {
    const win = this.compute_window();
    if (this.els.statusWindow) {
      this.els.statusWindow.textContent =
        `TF ${this.market.timeframe} | barras ${win.count} | offset ${this.offset}`;
    }
    if (this.els.statusHover) {
      if (this._hoverIndex !== null &&
          this._hoverIndex >= 0 && this._hoverIndex < this.market.candles.length) {
        const c = this.market.candles[this._hoverIndex];
        const a = this.market.atr[this._hoverIndex];
        const atrTxt = (a === null || a === undefined) ? "-" : a.toFixed(2);
        const dow   = diaSemana(c.time);
        const fecha = c.time.slice(0, 10);
        const hora  = c.time.slice(11, 16);
        this.els.statusHover.textContent =
          `${dow} ${fecha} ${hora}  O:${c.open} H:${c.high} L:${c.low} C:${c.close}  ATR:${atrTxt}`;
      } else {
        this.els.statusHover.textContent = "Mueve el cursor sobre el grafico...";
      }
    }
  }
  reset_view() {
    this.visible_bars = 120;
    this.offset = 0;
    this.price_auto = true;
    this.request_render();
  }
}
