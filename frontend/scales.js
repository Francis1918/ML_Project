// ============================================================
//  scales.js -- Traductor entre coordenadas de DATOS y PANTALLA.
//  NUNCA se mezclan. Eje X comun; eje Y propio de cada panel.
//  'plot_width' = ancho de dibujo (excluye el margen derecho de precios).
// ============================================================

"use strict";

class Scales {
  constructor(opts = {}) {
    this.width       = opts.width       ?? 800;
    this.height      = opts.height      ?? 400;
    this.plot_width  = opts.plot_width  ?? this.width;
    this.first_index = opts.first_index ?? 0;
    this.bar_width   = opts.bar_width   ?? 8;
    this.min_value   = opts.min_value   ?? 0;
    this.max_value   = opts.max_value   ?? 1;
  }

  // ---------- Eje X ----------
  index_to_x(index)        { return (index - this.first_index) * this.bar_width; }
  index_to_center_x(index) { return this.index_to_x(index) + this.bar_width / 2; }
  x_to_index_float(x)      { return this.first_index + x / this.bar_width; }
  x_to_index(x)            { return Math.floor(this.x_to_index_float(x)); }

  // ---------- Eje Y (invertido: y=0 arriba) ----------
  value_to_y(value) {
    const range = (this.max_value - this.min_value) || 1;
    const frac  = (value - this.min_value) / range;
    return this.height - frac * this.height;
  }
  y_to_value(y) {
    const frac = (this.height - y) / this.height;
    return this.min_value + frac * (this.max_value - this.min_value);
  }

  // ---------- Actualizadores ----------
  set_size(width, height, plot_width) {
    this.width  = width;
    this.height = height;
    this.plot_width = plot_width ?? width;
  }
  set_x_window(first_index, bar_width) {
    this.first_index = first_index;
    this.bar_width   = bar_width;
  }
  set_y_range(min_value, max_value) {
    this.min_value = min_value;
    this.max_value = max_value;
  }

  // ---------- Dibujo del eje vertical (precios / valores) ----------
  draw_y_scale(ctx, formatter) {
    const range = this.max_value - this.min_value;
    if (range <= 0) return;

    // Cantidad de divisiones proporcional a la altura del panel:
    // ~1 tick cada 28px, mínimo 8, máximo 30.
    const targetTicks = Math.min(30, Math.max(8, Math.floor(this.height / 28)));

    // Paso limpio: snap a 1 / 2 / 2.5 / 5 / 10 × 10^n
    const rawStep = range / targetTicks;
    const mag     = Math.pow(10, Math.floor(Math.log10(rawStep || 1)));
    const norm    = rawStep / mag;
    let niceNorm;
    if      (norm <= 1)   niceNorm = 1;
    else if (norm <= 2)   niceNorm = 2;
    else if (norm <= 2.5) niceNorm = 2.5;
    else if (norm <= 5)   niceNorm = 5;
    else                  niceNorm = 10;
    const step = niceNorm * mag;

    ctx.font = "11px -apple-system, Arial, sans-serif";
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";

    const firstIdx = Math.ceil(this.min_value / step);
    let lastY = Infinity;
    for (let i = firstIdx; ; i++) {
      const v    = Math.round(i * step * 1e9) / 1e9;
      if (v > this.max_value + step * 0.01) break;
      const yRaw = this.value_to_y(v);
      if (yRaw < 0 || yRaw > this.height) continue;
      // Evitar solape de etiquetas (mínimo 11px entre líneas)
      if (lastY - yRaw < 11) continue;
      lastY = yRaw;

      ctx.strokeStyle = "#1c212e";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, Math.round(yRaw) + 0.5);
      ctx.lineTo(this.plot_width, Math.round(yRaw) + 0.5);
      ctx.stroke();

      let yText = yRaw;
      if (yText < 8)               yText = 8;
      if (yText > this.height - 8) yText = this.height - 8;

      ctx.fillStyle = "#868993";
      ctx.fillText(formatter(v), this.plot_width + 6, yText);
    }
  }
}
