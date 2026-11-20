// pill-bg.js : Remotion-style choreographed SVG pill backdrop + WCAG 2.2.2 motion pause control
(() => {
  'use strict';

  const STORAGE_KEY = 'pharmacy_pill_motion';
  const SVG_NS = 'http://www.w3.org/2000/svg';

  const THEMES = {
    portal: {
      pageColors: ['#006241', '#00754a', '#cba258', '#8cc5ae'],
      heroColors: ['#d4e9e2', '#cba258', '#9fd2bf', '#f5e7c8'],
      speedScale: 1,
      ambientOpacity: 0.13,
      heroOpacity: 0.2,
      shapes: ['capsule', 'tablet', 'caplet', 'softgel'],
    },
    inventory: {
      pageColors: ['#1e3932', '#2b5148', '#cba258', '#7ea99a'],
      heroColors: ['#d4e9e2', '#cba258', '#a8c5bb', '#f0dec0'],
      speedScale: 1.15,
      ambientOpacity: 0.12,
      heroOpacity: 0.19,
      shapes: ['capsule', 'tablet', 'caplet', 'capsule'],
    },
    catalog: {
      pageColors: ['#006241', '#2b5148', '#cba258', '#5b8779'],
      heroColors: ['#d4e9e2', '#cba258', '#8cc5ae', '#f5e7c8'],
      speedScale: 1.08,
      ambientOpacity: 0.13,
      heroOpacity: 0.21,
      shapes: ['capsule', 'tablet', 'caplet', 'softgel'],
    },
  };

  // Perimeter coordinates keep cards and tables clean while floating along gutters
  const PAGE_SLOTS = [
    { x: '1.5%',  y: '14%', w: 96,  r: -24, anim: 'a', dur: 26, delay: -4,  mobile: true },
    { x: '91.5%', y: '18%', w: 86,  r: 28,  anim: 'b', dur: 30, delay: -12, mobile: true },
    { x: '3%',    y: '46%', w: 66,  r: 14,  anim: 'c', dur: 24, delay: -8,  mobile: false },
    { x: '93%',   y: '50%', w: 92,  r: -18, anim: 'o', dur: 34, delay: -19, mobile: false },
    { x: '2%',    y: '78%', w: 88,  r: 20,  anim: 'b', dur: 32, delay: -14, mobile: true },
    { x: '91%',   y: '80%', w: 72,  r: -32, anim: 'a', dur: 28, delay: -22, mobile: true },
    { x: '46%',   y: '90%', w: 82,  r: 12,  anim: 'c', dur: 36, delay: -9,  mobile: false },
    { x: '14%',   y: '89%', w: 60,  r: -12, anim: 'o', dur: 31, delay: -16, mobile: false },
  ];

  const HERO_SLOTS = [
    { x: '4%',  y: '14%', w: 74, r: -20, anim: 'a', dur: 24, delay: -3,  mobile: false },
    { x: '42%', y: '8%',  w: 62, r: 22,  anim: 'c', dur: 28, delay: -11, mobile: true },
    { x: '86%', y: '10%', w: 96, r: -28, anim: 'b', dur: 26, delay: -7,  mobile: true },
    { x: '66%', y: '70%', w: 78, r: 16,  anim: 'o', dur: 32, delay: -15, mobile: false },
    { x: '92%', y: '66%', w: 64, r: 34,  anim: 'a', dur: 29, delay: -20, mobile: true },
  ];

  function svgEl(tag, attrs) {
    const node = document.createElementNS(SVG_NS, tag);
    for (const [k, v] of Object.entries(attrs)) {
      node.setAttribute(k, String(v));
    }
    return node;
  }

  function buildPillSvg(shape, primary, secondary, isHero) {
    const strokeCol = isHero ? 'rgba(255,255,255,0.55)' : primary;
    if (shape === 'tablet') {
      const svg = svgEl('svg', { viewBox: '0 0 72 72', width: '72', height: '72', 'aria-hidden': 'true' });
      svg.append(
        svgEl('circle', { cx: 36, cy: 36, r: 29, fill: primary, stroke: strokeCol, 'stroke-width': 2 }),
        svgEl('circle', { cx: 36, cy: 36, r: 22, fill: secondary, opacity: 0.45 }),
        svgEl('line', {
          x1: 18, y1: 36, x2: 54, y2: 36,
          stroke: isHero ? '#1e3932' : '#ffffff',
          'stroke-width': 3,
          'stroke-linecap': 'round',
          opacity: 0.75,
        })
      );
      return svg;
    }
    if (shape === 'caplet') {
      const svg = svgEl('svg', { viewBox: '0 0 112 50', width: '112', height: '50', 'aria-hidden': 'true' });
      svg.append(
        svgEl('rect', {
          x: 4, y: 6, width: 104, height: 38, rx: 19,
          fill: primary, stroke: strokeCol, 'stroke-width': 2,
        }),
        svgEl('line', {
          x1: 56, y1: 9, x2: 56, y2: 41,
          stroke: secondary, 'stroke-width': 2.4, 'stroke-linecap': 'round', opacity: 0.7,
        }),
        svgEl('line', {
          x1: 22, y1: 15, x2: 44, y2: 15,
          stroke: '#ffffff', 'stroke-width': 2.5, 'stroke-linecap': 'round', opacity: 0.5,
        })
      );
      return svg;
    }
    if (shape === 'softgel') {
      const svg = svgEl('svg', { viewBox: '0 0 92 52', width: '92', height: '52', 'aria-hidden': 'true' });
      svg.append(
        svgEl('ellipse', {
          cx: 46, cy: 26, rx: 40, ry: 19,
          fill: primary, stroke: strokeCol, 'stroke-width': 2,
        }),
        svgEl('path', {
          d: 'M24 18 C36 12, 54 12, 66 17',
          fill: 'none', stroke: secondary, 'stroke-width': 3, 'stroke-linecap': 'round', opacity: 0.75,
        })
      );
      return svg;
    }
    // Default capsule (two-tone seam)
    const uid = 'cap_' + Math.random().toString(36).slice(2, 8);
    const svg = svgEl('svg', { viewBox: '0 0 120 56', width: '120', height: '56', 'aria-hidden': 'true' });
    const defs = svgEl('defs', {});
    const clip = svgEl('clipPath', { id: uid });
    clip.append(svgEl('rect', { x: 4, y: 6, width: 112, height: 44, rx: 22 }));
    defs.append(clip);
    const g = svgEl('g', { 'clip-path': `url(#${uid})` });
    g.append(
      svgEl('rect', { x: 4, y: 6, width: 56, height: 44, fill: primary }),
      svgEl('rect', { x: 60, y: 6, width: 56, height: 44, fill: secondary }),
      svgEl('line', { x1: 60, y1: 6, x2: 60, y2: 50, stroke: strokeCol, 'stroke-width': 1.8, opacity: 0.6 }),
      svgEl('line', { x1: 24, y1: 16, x2: 50, y2: 16, stroke: '#ffffff', 'stroke-width': 2.5, 'stroke-linecap': 'round', opacity: 0.48 })
    );
    svg.append(
      defs,
      g,
      svgEl('rect', {
        x: 4, y: 6, width: 112, height: 44, rx: 22,
        fill: 'none', stroke: strokeCol, 'stroke-width': 2,
      })
    );
    return svg;
  }

  function createLayer(cls, slots, colors, opacity, shapes, speedScale, isHero) {
    const layer = document.createElement('div');
    layer.className = cls;
    layer.setAttribute('aria-hidden', 'true');
    slots.forEach((slot, idx) => {
      const sprite = document.createElement('span');
      sprite.className = 'pill-sprite' + (slot.mobile ? '' : ' pill-desktop-only');
      sprite.dataset.anim = slot.anim;
      sprite.style.setProperty('--px', slot.x);
      sprite.style.setProperty('--py', slot.y);
      sprite.style.setProperty('--pw', slot.w + 'px');
      sprite.style.setProperty('--pr', slot.r + 'deg');
      sprite.style.setProperty('--po', String(opacity));
      sprite.style.setProperty('--pd', Math.round(slot.dur * speedScale) + 's');
      sprite.style.setProperty('--pdelay', slot.delay + 's');

      const cA = colors[idx % colors.length];
      const cB = isHero ? 'rgba(255,255,255,0.72)' : '#faf6ee';
      const shape = shapes[idx % shapes.length];
      sprite.append(buildPillSvg(shape, cA, cB, isHero));
      layer.append(sprite);
    });
    return layer;
  }

  function readPaused() {
    try {
      return localStorage.getItem(STORAGE_KEY) === 'paused';
    } catch {
      return false;
    }
  }

  function savePaused(paused) {
    try {
      localStorage.setItem(STORAGE_KEY, paused ? 'paused' : 'running');
    } catch {
      /* ignore */
    }
  }

  function syncMotionDom(paused, btn, labelSpan) {
    document.documentElement.dataset.pillMotion = paused ? 'paused' : 'running';
    if (labelSpan) {
      labelSpan.textContent = paused ? 'เล่นพื้นหลังเม็ดยา' : 'พักพื้นหลังเม็ดยา';
    }
    if (btn) {
      btn.removeAttribute('aria-pressed');
    }
  }

  function init() {
    if (!document.body || document.querySelector('.page-pill-bg')) return;
    const themeName = document.body.dataset.pillTheme || 'portal';
    const theme = THEMES[themeName] || THEMES.portal;

    const pageLayer = createLayer(
      'page-pill-bg',
      PAGE_SLOTS,
      theme.pageColors,
      theme.ambientOpacity,
      theme.shapes,
      theme.speedScale,
      false
    );
    document.body.prepend(pageLayer);

    const hero = document.querySelector('.hero-band');
    if (hero) {
      const heroLayer = createLayer(
        'hero-pill-stage',
        HERO_SLOTS,
        theme.heroColors,
        theme.heroOpacity,
        theme.shapes,
        theme.speedScale,
        true
      );
      hero.prepend(heroLayer);
    }

    const footerLinks = document.querySelector('.site-footer .footer-links') || document.querySelector('.site-footer .footer-inner');
    let toggleBtn = null;
    let labelSpan = null;
    if (footerLinks && !document.getElementById('pillMotionToggle')) {
      toggleBtn = document.createElement('button');
      toggleBtn.type = 'button';
      toggleBtn.id = 'pillMotionToggle';
      toggleBtn.className = 'pill-motion-btn';
      const dot = document.createElement('span');
      dot.className = 'pill-motion-dot';
      dot.setAttribute('aria-hidden', 'true');
      labelSpan = document.createElement('span');
      toggleBtn.append(dot, labelSpan);
      footerLinks.append(toggleBtn);
    }

    let paused = readPaused();
    syncMotionDom(paused, toggleBtn, labelSpan);

    if (toggleBtn) {
      toggleBtn.addEventListener('click', () => {
        paused = !paused;
        savePaused(paused);
        syncMotionDom(paused, toggleBtn, labelSpan);
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
