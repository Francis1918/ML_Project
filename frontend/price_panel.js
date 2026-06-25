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
    const ctx   = this.ctx;
    const s     = this.scale;
    const bodyW = Math.max(1, s.bar_width * 0.7);

    ctx.fillStyle = this.colorBg;
    ctx.fillRect(0, 0, s.width, s.height);

    s.draw_y_scale(ctx, (v) => v.toFixed(2));

    // Barras de volumen (detrás de las velas, zona inferior 20% del panel)
    let maxVol = 0;
    for (const c of candles) if (c.volume > maxVol) maxVol = c.volume;
    if (maxVol > 0) {
      const maxH = s.height * 0.20;
      ctx.save();
      ctx.globalAlpha = 0.45;
      for (let k = 0; k < candles.length; k++) {
        const c    = candles[k];
        const cx   = s.index_to_center_x(firstIndex + k);
        const barH = (c.volume / maxVol) * maxH;
        ctx.fillStyle = c.close >= c.open ? this.colorUp : this.colorDown;
        ctx.fillRect(cx - bodyW / 2, s.height - barH, bodyW, barH);
      }
      ctx.restore();
    }

    // Velas
    for (let k = 0; k < candles.length; k++) {
      const c     = candles[k];
      const cx    = s.index_to_center_x(firstIndex + k);
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

  draw_last_price(lastClose, lastOpen) {
    const s = this.scale;
    if (lastClose < s.min_value || lastClose > s.max_value) return;
    const ctx   = this.ctx;
    const y     = s.value_to_y(lastClose);
    const color = lastClose >= lastOpen ? this.colorUp : this.colorDown;
    const axisX = s.plot_width;
    const axisW = s.width - axisX;
    if (axisW < 2) return;

    // Línea horizontal punteada
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth   = 1;
    ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(0, Math.round(y) + 0.5);
    ctx.lineTo(axisX, Math.round(y) + 0.5);
    ctx.stroke();

    // Etiqueta en el eje Y
    const h = 16;
    ctx.setLineDash([]);
    ctx.fillStyle = color;
    ctx.fillRect(axisX, Math.round(y) - h / 2, axisW, h);
    ctx.fillStyle = "#fff";
    ctx.font = "11px -apple-system, Arial, sans-serif";
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";
    ctx.fillText(lastClose.toFixed(2), axisX + 4, Math.round(y));
    ctx.restore();
  }

  // visibleCount : numero de velas visibles en pantalla
  // y            : coordenada Y donde empieza la franja del eje de tiempo
  // timeframe    : "1m" | "5m" | "15m"
  draw_time_axis(ctx, allCandles, firstIndex, lastIndex, visibleCount, y, timeframe) {
    const s = this.scale;
    ctx.font = "11px -apple-system, Arial, sans-serif";
    ctx.textBaseline = "top";
    ctx.textAlign    = "center";

    // Intervalo de etiqueta: ideal = (velas_visibles × min_por_vela) / 33
    // → buscar el siguiente intervalo estandar en la lista.
    const tfMin = { '1m': 1, '5m': 5, '15m': 15 }[timeframe] || 1;
    const STD   = [1, 5, 15, 30, 60, 120, 240, 360, 720, 1440];
    const ideal = (visibleCount * tfMin) / 33;
    const intervalMin = STD.find(iv => iv >= ideal) || 1440;

    const MESES = ['Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Sep','Oct','Nov','Dic'];
    const minGap = 55;
    let lastLabelX = -Infinity;

    for (let i = firstIndex; i <= lastIndex; i++) {
      const c = allCandles[i];
      if (!c) continue;

      const mt = c.time.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
      if (!mt) continue;
      const totalMin = +mt[4] * 60 + +mt[5];

      const prevC       = i > 0 ? allCandles[i - 1] : null;
      const isNewMonth  = !prevC || prevC.time.slice(0, 7) !== c.time.slice(0, 7);
      const isNewDay    = !prevC || prevC.time.slice(0, 10) !== c.time.slice(0, 10);
      const isInterval  = (totalMin % intervalMin) === 0;
      // Primer candle visible: anclar la etiqueta de día (estilo TradingView)
      const isFirstVis  = i === firstIndex;

      if (!isNewDay && !isInterval && !isFirstVis) continue;

      const x = s.index_to_center_x(i);
      if (x < 0 || x > s.plot_width) continue;

      // Línea vertical de grilla (solo para cambios de día e intervalos regulares)
      if (isNewDay || isInterval) {
        ctx.strokeStyle = "#1c212e";
        ctx.lineWidth   = 1;
        ctx.setLineDash([]);
        ctx.beginPath();
        ctx.moveTo(Math.round(x) + 0.5, 0);
        ctx.lineTo(Math.round(x) + 0.5, y - 2);
        ctx.stroke();
      }

      // Etiqueta (solo si hay espacio suficiente respecto a la anterior)
      if (x - lastLabelX < minGap) continue;
      lastLabelX = x;

      if (isNewMonth) {
        // Inicio de mes: "Abr 1", "May 15" — más brillante
        ctx.fillStyle = "#d1d4dc";
        ctx.fillText(MESES[+mt[2] - 1] + " " + +mt[3], x, y);
      } else if (isNewDay || isFirstVis) {
        // Nuevo día o etiqueta anclada del primer candle visible — tono medio
        ctx.fillStyle = "#a8aab4";
        ctx.fillText(diaSemana(c.time) + " " + +mt[3], x, y);
      } else {
        // Marca de hora/minuto: "09:30" — hora en punto más brillante
        ctx.fillStyle = totalMin % 60 === 0 ? "#a8aab4" : "#868993";
        ctx.fillText(c.time.slice(11, 16), x, y);
      }
    }
  }
}
