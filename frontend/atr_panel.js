// ============================================================
//  atr_panel.js -- Linea del ATR con su escala vertical propia.
// ============================================================

"use strict";

class ATRPanel {
  constructor(canvas, scale) {
    this.canvas = canvas;
    this.ctx    = canvas.getContext("2d");
    this.scale  = scale;
    this.colorLine = "#2962ff";
    this.colorBg   = "#131722";
  }

  set_scale(scale) { this.scale = scale; }

  get_y_range(values) {
    let min = Infinity, max = -Infinity;
    for (const v of values) {
      if (v === null || v === undefined) continue;
      if (v < min) min = v;
      if (v > max) max = v;
    }
    if (!isFinite(min) || !isFinite(max)) return { min: 0, max: 1 };
    const pad = (max - min) * 0.12 || 1;
    return { min: Math.max(0, min - pad), max: max + pad };
  }

  render(values, firstIndex) {
    const ctx = this.ctx;
    const s   = this.scale;

    ctx.fillStyle = this.colorBg;
    ctx.fillRect(0, 0, s.width, s.height);

    // Eje Y propio (cuadricula + etiquetas)
    s.draw_y_scale(ctx, (v) => v.toFixed(2));

    ctx.strokeStyle = this.colorLine;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    let started = false;
    for (let k = 0; k < values.length; k++) {
      const v = values[k];
      if (v === null || v === undefined) { started = false; continue; }
      const x = s.index_to_center_x(firstIndex + k);
      const y = s.value_to_y(v);
      if (!started) { ctx.moveTo(x, y); started = true; }
      else          { ctx.lineTo(x, y); }
    }
    ctx.stroke();
  }
}
