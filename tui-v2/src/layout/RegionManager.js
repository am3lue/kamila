const EventEmitter = require('events');

function resolveAxis(value, total, offset) {
  if (typeof value === 'number') return value;
  if (typeof value !== 'string') return 0;
  let v = value.trim();
  if (v === 'flex') return offset;
  const m = /^([\d.]+)%\s*(?:-\s*([\d.]+)%?)?$/.exec(v);
  if (m) {
    const pct = parseFloat(m[1]);
    const minus = m[2] ? parseFloat(m[2]) : 0;
    if (Number.isFinite(pct)) return Math.floor(total * pct / 100) - Math.floor(total * minus / 100);
  }
  const n2 = parseFloat(v);
  return Number.isFinite(n2) ? n2 : 0;
}

function resolveAbove(value, y, regions) {
  if (typeof value !== 'string') return null;
  const m = /^above:(.+)$/.exec(value.trim());
  if (!m) return null;
  const anchor = regions.get(m[1]);
  if (!anchor) return null;
  return Math.max(0, anchor.y - y);
}

function resolveFlex(value, fullTotal, totalRemaining, flex, flexTotal) {
  if (typeof value === 'number') return value;
  if (typeof value !== 'string') return totalRemaining;
  const v = value.trim();
  if (v === 'flex') {
    if (flexTotal > 0 && Number.isFinite(totalRemaining)) {
      return Math.floor(totalRemaining * (flex / flexTotal));
    }
    return Math.max(0, Math.floor(totalRemaining));
  }
  const m = /^([\d.]+)%\s*(?:-\s*([\d.]+)%?)?$/.exec(v);
  if (m) {
    const pct = parseFloat(m[1]);
    const minus = m[2] ? parseFloat(m[2]) : 0;
    if (Number.isFinite(pct)) return Math.floor(fullTotal * pct / 100) - Math.floor(fullTotal * minus / 100);
  }
  const n2 = parseFloat(v);
  return Number.isFinite(n2) ? n2 : 0;
}

class RegionManager extends EventEmitter {
  constructor(screen) {
    super();
    this.screen = screen;
    this.definitions = new Map();
    this.regions = new Map();
    this.resizeTimer = null;
    this.lastWidth = 0;
    this.lastHeight = 0;
    this.lastVersion = 0;
    this.version = 0;

    screen.on('resize', () => this.debouncedRecalc());
  }

  define(name, opts = {}) {
    this.definitions.set(name, {
      x: opts.x ?? 0,
      y: opts.y ?? 0,
      width: opts.width ?? '100%',
      height: opts.height ?? '100%',
      minWidth: opts.minWidth,
      maxWidth: opts.maxWidth,
      minHeight: opts.minHeight,
      maxHeight: opts.maxHeight,
      flex: opts.flex || 0,
      after: opts.after,
      fillTo: opts.fillTo,
    });
    this.version += 1;
    return this;
  }

  calculate() {
    const sw = this.screen.width;
    const sh = this.screen.height;
    if (sw === this.lastWidth && sh === this.lastHeight && this.regions.size && this.version === this.lastVersion) return this.regions;

    this.lastWidth = sw;
    this.lastHeight = sh;
    this.lastVersion = this.version;

    const defs = Array.from(this.definitions.entries());
    const flexTotal = defs.reduce((sum, [, d]) => sum + (d.flex || 0), 0);
    let offsetX = 0;
    let offsetY = 0;

    for (const [name, def] of defs) {
      if (def.after || def.fillTo) continue;

      const x = resolveAxis(def.x, sw, offsetX);
      const y = resolveAxis(def.y, sh, offsetY);
      const width = resolveFlex(def.width, sw, sw - offsetX, def.flex, flexTotal);
      let height = resolveFlex(def.height, sh, sh - offsetY, def.flex, flexTotal);
      const aboveH = resolveAbove(def.height, y, this.regions);
      if (aboveH !== null) height = aboveH;

      let w = Math.max(0, width);
      let h = Math.max(0, height);
      if (def.minWidth && w < def.minWidth) w = def.minWidth;
      if (def.maxWidth && w > def.maxWidth) w = def.maxWidth;
      if (def.minHeight && h < def.minHeight) h = def.minHeight;
      if (def.maxHeight && h > def.maxHeight) h = def.maxHeight;

      let rx = x;
      if (rx + w > sw) rx = Math.max(0, sw - w);

      this.regions.set(name, { x: rx, y, width: w, height: h });
      offsetX = rx + w;
      offsetY = y + h;
    }

    for (const [name, def] of defs) {
      if (!def.after && !def.fillTo) continue;
      const anchor = def.after ? this.regions.get(def.after) : this.regions.get(def.fillTo);
      if (!anchor) continue;

      let x;
      let w;
      if (def.after) {
        x = anchor.x + anchor.width;
        const endRef = def.fillTo ? this.regions.get(def.fillTo) : null;
        w = endRef ? endRef.x - x : sw - x;
      } else {
        x = resolveAxis(def.x, sw, 0);
        w = anchor.x - x;
      }

      const y = resolveAxis(def.y, sh, 0);
      let height = resolveFlex(def.height, sh, sh, 0, 0);
      const aboveH = resolveAbove(def.height, y, this.regions);
      if (aboveH !== null) height = aboveH;
      let h = Math.max(0, height);
      if (def.minHeight && h < def.minHeight) h = def.minHeight;
      if (def.maxHeight && h > def.maxHeight) h = def.maxHeight;

      let px = Math.max(0, x);
      if (px + w > sw) px = Math.max(0, sw - w);

      this.regions.set(name, { x: px, y, width: Math.max(0, w), height: h });
    }

    this.emit('change', this.regions);
    return this.regions;
  }

  get(name) {
    return this.regions.get(name);
  }

  getAll() {
    return new Map(this.regions);
  }

  debouncedRecalc() {
    clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout(() => {
      const oldRegions = new Map(this.regions);
      this.lastWidth = 0;
      this.lastHeight = 0;
      this.calculate();
      this.preserveScroll(oldRegions);
    }, 50);
  }

  preserveScroll(oldRegions) {
    for (const [name, region] of this.regions) {
      const old = oldRegions.get(name);
      if (old && region.width === old.width && region.height === old.height) {
        this.emit('resize:preserve', name, region, old);
      }
    }
  }

  onResize(cb) {
    this.on('change', cb);
  }
}

module.exports = { RegionManager };