"use strict";

// Devuelve el dia de la semana (lun..dom) de una fecha ISO, sin que la
// zona horaria del navegador afecte el resultado.
function diaSemana(iso) {
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return "";
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).getUTCDay();
  return ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"][d];
}

class PricePanel {
  constructor(canvas, scale) {
    this.canvas = canvas;
    this.ctx    = canvas.getContext("2d");
    this.scale  = scale;
    this.colorUp   = "#26a69a";
    this.colorDown = "#ef5350";
    this.colorBg   = "#131722";
  }

  set_scale(scale) { this.scale = scale; }

  get_y_range(candles) {
    let min = Infinity, max = -Infinity;
    for (const c of candles) {
      if (c.low  < min) min = c.low;
      if (c.high > max) max = c.high;
    }
    if (!isFinite(min) || !isFinite(max)) return { min: 0, max: 1 };
    const pad = (max - min) * 0.08 || 1;
    return { min: min - pad, max: max + pad };
  }

  render(candles, firstIndex) {
    const ctx = this.ctx;
    const s   = this.scale;

    ctx.fillStyle = this.colorBg;
    ctx.fillRect(0, 0, s.width, s.height);

    s.draw_y_scale(ctx, (v) => v.toFixed(2));

    const bodyW = Math.max(1, s.bar_width * 0.7);
    for (let k = 0; k < candles.length; k++) {
      const c   = candles[k];
      const cx  = s.index_to_center_x(firstIndex + k);
      const isUp  = c.close >= c.open;
      const color = isUp ? this.colorUp : this.colorDown;

      const yHigh = s.value_to_y(c.high);
      const yLow  = s.value_to_y(c.low);
      ctx.strokeStyle = color;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(Math.round(cx) + 0.5, yHigh);
      ctx.lineTo(Math.round(cx) + 0.5, yLow);
      ctx.stroke();

      const yOpen  = s.value_to_y(c.open);
      const yClose = s.value_to_y(c.close);
      const top    = Math.min(yOpen, yClose);
      const h      = Math.max(1, Math.abs(yClose - yOpen));
      ctx.fillStyle = color;
      ctx.fillRect(cx - bodyW / 2, top, bodyW, h);
    }
  }

  draw_time_axis(ctx, anchors, firstIndex, lastIndex, y) {
    const s = this.scale;
    ctx.font = "11px -apple-system, Arial, sans-serif";
    ctx.textBaseline = "top";
    ctx.textAlign = "center";

    // Días tienen prioridad: umbral independiente y más pequeño.
    // Horas/subhoras necesitan espacio desde cualquier etiqueta anterior.
    const minGapDay = 50;
    const minGapSub = 55;
    let lastDayX = -Infinity;
    let lastAnyX = -Infinity;

    for (const a of anchors) {
      if (a.index < firstIndex || a.index > lastIndex) continue;
      const x = s.index_to_center_x(a.index);
      if (x < 0 || x > s.plot_width) continue;

      // Línea vertical para todos los anchors
      ctx.strokeStyle = "#1c212e";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(Math.round(x) + 0.5, 0);
      ctx.lineTo(Math.round(x) + 0.5, y - 2);
      ctx.stroke();

      if (a.is_new_day) {
        if (x - lastDayX < minGapDay) continue;
        lastDayX = x;
        lastAnyX = x;
        ctx.fillStyle = "#d1d4dc";
        ctx.fillText(diaSemana(a.time) + " " + a.time.slice(5, 10), x, y);
      } else {
        if (x - lastAnyX < minGapSub) continue;
        lastAnyX = x;
        // Hora en punto más brillante que sub-hora
        const isHour = a.time.slice(14, 16) === "00";
        ctx.fillStyle = isHour ? "#a8aab4" : "#868993";
        ctx.fillText(a.time.slice(11, 16), x, y);
      }
    }
  }
}
