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
const MIN_BARS = 2;
const MAX_BARS = 6000;

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
  set_market(market) { this.market = market; }
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
    const first = Math.max(0, Math.min(n - 1, virtualFirst));
    const last  = Math.max(0, Math.min(n - 1, virtualLast));
    return { first, last, virtualFirst, count };
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
    this.priceScale.set_x_window(win.virtualFirst, barW);
    this.priceScale.set_y_range(yMin, yMax);
    this.pricePanel.render(candles, win.first);
    const lastC = this.market.candles[this.market.candles.length - 1];
    if (lastC) this.pricePanel.draw_last_price(lastC.close, lastC.open);
    const sizeA = this._fit_canvas(this.els.atrCanvas);
    const plotH = sizeA.h - TIME_AXIS_H;
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
  _enter_manual_atr_mode() {
    if (this.atr_auto) {
      this.atr_auto = false;
      this.atr_min = this.atrScale.min_value;
      this.atr_max = this.atrScale.max_value;
    }
  }
  bind_events() {
    // Botones de modo (Auto / Manual)
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
      cv.addEventListener("mousemove", (e) => this._on_canvas_move(e, cv));
      cv.addEventListener("mouseleave", () => this._on_canvas_leave());
    }
    window.addEventListener("mousemove", (e) => this._on_mouse_move(e));
    window.addEventListener("mouseup", (e) => this._on_mouse_up(e));
  }
  _on_mouse_down(e, panel) {
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
    // Cursor sobre eje Y o Shift → zoom vertical (siempre disponible)
    if (e.shiftKey || mouseX > this.priceScale.plot_width) {
      if (panel === "atr") { this._vertical_zoom_atr(e.deltaY); }
      else                 { this._vertical_zoom(e.deltaY);     }
    // Ctrl → zoom anclado al crosshair (pivote en la vela apuntada)
    } else if (e.ctrlKey) {
      this._zoom_at_cursor(e.deltaY, mouseX);
    } else {
      this._horizontal_zoom(e.deltaY, mouseX);
    }
  }
  _horizontal_zoom(delta, mouseX) {
    const win      = this.compute_window();
    const prevBars = this.visible_bars;
    const factor   = delta > 0 ? 1.15 : 1 / 1.15;
    this.visible_bars = factor < 1
      ? Math.floor(this.visible_bars * factor)
      : Math.ceil(this.visible_bars * factor);
    this._clamp_bars();
    if (this.mode === "auto") {
      this.offset = Math.max(0, this.offset);
    } else if (this.visible_bars !== prevBars) {
      // Manual: anclar al cursor solo si el zoom realmente cambio.
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
    const factor   = delta > 0 ? 1.15 : 1 / 1.15;
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
    }
    this._clamp_offset();
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
      this._draw_hline(priceCtx, this._mouse.y, this.priceScale.plot_width);
      // Caja de precio sobre eje Y
      const price = this.priceScale.y_to_value(this._mouse.y);
      this._draw_y_label(priceCtx, this._mouse.y, this.priceScale, price.toFixed(2));
    } else {
      this._draw_hline(atrCtx, this._mouse.y, this.atrScale.plot_width);
      // Caja de valor ATR sobre eje Y
      const atrVal = this.atrScale.y_to_value(this._mouse.y);
      this._draw_y_label(atrCtx, this._mouse.y, this.atrScale, atrVal.toFixed(2));
    }

    // Etiqueta temporal (siempre, en el eje de tiempo del panel ATR)
    const c = this.market.candles[this._hoverIndex];
    if (c) {
      const label = `${diaSemana(c.time)} ${c.time.slice(5, 10)} ${c.time.slice(11, 16)}`;
      this._draw_x_label(atrCtx, cx, label);
    }
  }
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
    ctx.textAlign = "left";
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
    ctx.textAlign = "center";
    ctx.fillText(label, Math.round(x), plotH + 1 + h / 2);
    ctx.restore();
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
        `TF ${this.market.timeframe} | ${this.mode} | barras ${win.count} | offset ${this.offset}`;
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
    this.atr_auto   = true;
    this.request_render();
  }
}
