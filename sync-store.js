(() => {
  'use strict';

  const API_URL = '/api/data';
  const DATASETS = {
    drugs: {
      key: 'drugs',
      label: 'ทะเบียนยา (Supabase drugs)',
      fileName: 'drugs.json',
      primaryKey: 'sku'
    },
    stock: {
      key: 'stock',
      label: 'สต็อกรายล็อต (Supabase stock)',
      fileName: 'stock.json',
      primaryKey: 'stock_id'
    },
    dispense: {
      key: 'dispense',
      label: 'ประวัติการจ่ายยา (Supabase dispense_log)',
      fileName: 'dispense_log.json',
      primaryKey: 'dispense_id'
    },
    catalog: {
      key: 'catalog',
      label: 'บัญชียารวมยอดคลัง (v_drug_catalog)',
      fileName: 'catalog.json',
      primaryKey: 'sku'
    },
    incidents: {
      key: 'incidents',
      label: 'อุบัติการณ์ความปลอดภัย (incidents)',
      fileName: 'incidents.json',
      primaryKey: 'incident_id'
    }
  };

  const PREFIX = 'pharmacy_supabase_';
  const HISTORY_KEY = `${PREFIX}sync_history_v1`;
  const AUTOSYNC_KEY = `${PREFIX}autosync_sec_v1`;
  const CHANNEL_NAME = 'pharmacy-supabase-sync';

  const listeners = new Set();
  const channel = typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel(CHANNEL_NAME) : null;

  let autoSyncTimer = null;
  let lastBundle = null;

  function hashString(str) {
    let h = 2166136261;
    for (let i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(16);
  }

  function safeParseStorage(key, fallback) {
    try {
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : fallback;
    } catch {
      return fallback;
    }
  }

  function safeSetStorage(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch {
      // Ignore quota errors cleanly
    }
  }

  function appendHistory(entry) {
    const list = safeParseStorage(HISTORY_KEY, []);
    list.unshift({ ...entry, ts: new Date().toISOString() });
    safeSetStorage(HISTORY_KEY, list.slice(0, 20));
  }

  function getHistory() {
    return safeParseStorage(HISTORY_KEY, []);
  }

  function normalizeBundle(raw) {
    if (!raw || !Array.isArray(raw.drugs?.items) || !Array.isArray(raw.stock?.items) || !Array.isArray(raw.dispense_log?.items)) {
      throw new Error('โครงสร้างข้อมูลจาก /api/data ไม่ครบถ้วน (ต้องมี drugs, stock, dispense_log)');
    }

    const asOf = String(raw.stock?.meta?.as_of || raw.drugs?.meta?.as_of || '').slice(0, 10);
    const serverToday = String(raw.stock?.meta?.server_today || raw.drugs?.meta?.server_today || '').slice(0, 10);
    const source = raw.drugs?.meta?.source || 'supabase';
    const baseMeta = { as_of: asOf, ...(serverToday ? { server_today: serverToday } : {}), source };

    const drugsItems = raw.drugs.items.map((d) => ({
      ...d,
      reorder_level: Number(d.reorder_level ?? 0),
      is_active: d.is_active !== false
    }));

    const stockItems = raw.stock.items.map((s) => ({
      ...s,
      qty_on_hand: Number(s.qty_on_hand ?? 0),
      unit_cost: Number(s.unit_cost ?? 0)
    }));

    const incidentsItems = Array.isArray(raw.incidents?.items) ? raw.incidents.items.map((inc) => ({ ...inc })) : [];
    const incidentsByDispense = new Map();
    for (const inc of incidentsItems) {
      if (!inc?.dispense_id) continue;
      if (!incidentsByDispense.has(inc.dispense_id)) {
        incidentsByDispense.set(inc.dispense_id, []);
      }
      incidentsByDispense.get(inc.dispense_id).push(inc);
    }

    const dispenseItems = raw.dispense_log.items.map((l) => {
      const incList = incidentsByDispense.get(l.dispense_id) || [];
      const incidentRef = incList.length ? incList.map((i) => i.incident_id).join(', ') : (l.incident_ref || null);
      return {
        ...l,
        qty: Number(l.qty ?? 0),
        type: l.type || 'dispense',
        ref_dispense_id: l.ref_dispense_id || null,
        incident_ref: incidentRef,
        incident_detail: incList[0] || null
      };
    });

    let catalogItems;
    let catalogMeta;
    if (Array.isArray(raw.catalog?.items)) {
      catalogItems = raw.catalog.items.map((c) => ({
        ...c,
        reorder_level: Number(c.reorder_level ?? 0),
        is_active: c.is_active !== false,
        lot_count: Number(c.lot_count ?? 0),
        usable_qty: Number(c.usable_qty ?? 0),
        quarantine_qty: Number(c.quarantine_qty ?? 0)
      }));
      catalogMeta = { ...baseMeta, ...(raw.catalog.meta || {}) };
    } else {
      // Fallback when crud.sql v_drug_catalog is unavailable
      const stockBySku = new Map();
      for (const s of stockItems) {
        if (!stockBySku.has(s.sku)) stockBySku.set(s.sku, []);
        stockBySku.get(s.sku).push(s);
      }
      catalogItems = drugsItems.map((d) => {
        const lots = stockBySku.get(d.sku) || [];
        const usableQty = lots
          .filter((s) => s.status === 'active' && s.expiry && (!asOf || s.expiry >= asOf))
          .reduce((sum, s) => sum + s.qty_on_hand, 0);
        const quarantineQty = lots
          .filter((s) => s.status === 'quarantine')
          .reduce((sum, s) => sum + s.qty_on_hand, 0);
        return {
          ...d,
          lot_count: lots.length,
          usable_qty: usableQty,
          quarantine_qty: quarantineQty
        };
      });
      catalogMeta = { ...baseMeta, fallback: true };
    }

    const drugs = { meta: { ...baseMeta, ...(raw.drugs.meta || {}) }, items: drugsItems };
    const stock = { meta: { ...baseMeta, ...(raw.stock.meta || {}) }, items: stockItems };
    const dispense = { meta: { ...baseMeta, ...(raw.dispense_log.meta || {}) }, items: dispenseItems };
    const catalog = { meta: catalogMeta, items: catalogItems };
    const incidents = { meta: { ...baseMeta, ...(raw.incidents?.meta || {}) }, items: incidentsItems };

    const hashes = {
      drugs: hashString(JSON.stringify(drugsItems)),
      stock: hashString(JSON.stringify(stockItems)),
      dispense: hashString(JSON.stringify(dispenseItems)),
      catalog: hashString(JSON.stringify(catalogItems)),
      incidents: hashString(JSON.stringify(incidentsItems))
    };

    const counts = {
      drugs: drugsItems.length,
      stock: stockItems.length,
      dispense: dispenseItems.length,
      catalog: catalogItems.length,
      incidents: incidentsItems.length
    };

    return {
      drugs,
      stock,
      dispense,
      catalog,
      incidents,
      syncMeta: {
        mode: 'supabase-api',
        source,
        asOf,
        serverToday,
        hashes,
        counts,
        catalogFallback: Boolean(catalogMeta.fallback),
        lastSyncAt: new Date().toISOString(),
        history: getHistory()
      }
    };
  }

  async function loadAll() {
    const res = await fetch(`${API_URL}?t=${Date.now()}`, { cache: 'no-store' });
    const text = await res.text();
    let raw = null;
    try {
      raw = JSON.parse(text);
    } catch {
      raw = null;
    }
    if (!res.ok) {
      const msg = raw?.error || raw?.message || `HTTP ${res.status}`;
      throw new Error(`/api/data: ${msg}`);
    }
    const bundle = normalizeBundle(raw);
    lastBundle = bundle;
    return bundle;
  }

  async function refresh({ broadcast = true, manual = true } = {}) {
    const prevHashes = lastBundle?.syncMeta?.hashes ? { ...lastBundle.syncMeta.hashes } : null;
    const prevCounts = lastBundle?.syncMeta?.counts ? { ...lastBundle.syncMeta.counts } : null;

    const fresh = await loadAll();
    const changed = [];
    if (prevHashes) {
      for (const k of Object.keys(DATASETS)) {
        if (prevHashes[k] !== fresh.syncMeta.hashes[k]) {
          changed.push(k);
        }
      }
    }

    if (manual || changed.length > 0) {
      appendHistory({
        dataset: changed.length ? changed.join(', ') : 'all',
        changedCount: changed.length,
        sourceLabel: manual ? 'manual-refresh' : 'auto-refresh',
        counts: fresh.syncMeta.counts
      });
      fresh.syncMeta.history = getHistory();
    }

    const detail = {
      type: 'api-synced',
      changed,
      prevCounts,
      manual,
      bundle: fresh
    };

    if (broadcast && channel && changed.length > 0) {
      channel.postMessage({ type: 'refresh', ts: Date.now() });
    }

    notify(detail);
    return detail;
  }

  function exportDatasetJson(datasetKey, bundle = lastBundle) {
    const spec = DATASETS[datasetKey];
    const target = bundle?.[datasetKey];
    if (!spec || !target) return;
    const text = JSON.stringify(target, null, 2) + '\n';
    const url = URL.createObjectURL(new Blob([text], { type: 'application/json;charset=utf-8' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = spec.fileName;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 500);
  }

  function getAutoSync() {
    return Number(safeParseStorage(AUTOSYNC_KEY, 0)) || 0;
  }

  function setAutoSync(seconds) {
    const sec = Number(seconds) || 0;
    safeSetStorage(AUTOSYNC_KEY, sec);
    if (autoSyncTimer) {
      clearInterval(autoSyncTimer);
      autoSyncTimer = null;
    }
    if (sec > 0) {
      autoSyncTimer = setInterval(() => {
        refresh({ broadcast: false, manual: false }).catch(() => {});
      }, sec * 1000);
    }
    return sec;
  }

  function notify(detail) {
    listeners.forEach((fn) => {
      try {
        fn(detail);
      } catch {
        // Isolate subscriber errors
      }
    });
  }

  function subscribe(fn) {
    listeners.add(fn);
    return () => listeners.delete(fn);
  }

  if (channel) {
    channel.addEventListener('message', async (ev) => {
      if (ev.data?.type !== 'refresh') return;
      try {
        const bundle = await loadAll();
        notify({ type: 'cross-tab-sync', bundle });
      } catch {
        // Ignore transient network errors during background tab sync
      }
    });
  }

  const savedAuto = getAutoSync();
  if (savedAuto > 0) setAutoSync(savedAuto);

  window.PharmacySync = {
    API_URL,
    DATASETS,
    loadAll,
    refresh,
    syncFromDisk: refresh,
    exportDatasetJson,
    getAutoSync,
    setAutoSync,
    getHistory,
    subscribe,
    getCurrentBundle: () => lastBundle
  };
})();
