/* Supabase-backed stand-in for the claude.ai artifact storage.
   Exposes the same shape the page already used: db.collection(...).onSnapshot/add,
   db.doc("coll/id").update/set/delete/onSnapshot, plus a per-browser user id. */
(function () {
  const cfg = window.WF_CONFIG || {};
  const isObj = v => v && typeof v === "object" && !Array.isArray(v);
  const merge = (a, b) => {
    if (!isObj(a) || !isObj(b)) return b;
    const out = { ...a };
    for (const k of Object.keys(b)) out[k] = k in a ? merge(a[k], b[k]) : b[k];
    return out;
  };
  const rid = () => (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2)).replace(/-/g, "");

  function browserId() {
    let id = null;
    try { id = localStorage.getItem("wf-uid"); } catch {}
    if (!id) { id = "b_" + rid().slice(0, 22); try { localStorage.setItem("wf-uid", id); } catch {} }
    return id;
  }

  // Login token: every write carries it, and the database checks what this player may change.
  let token = "";

  async function createDb() {
    if (!cfg.supabaseUrl || !cfg.supabaseAnonKey || !window.supabase) return null;
    const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey);
    const cache = new Map();          // "coll/id" -> data
    const listeners = new Set();      // () => void
    const key = (c, i) => c + "/" + i;
    const emit = () => listeners.forEach(fn => { try { fn(); } catch (e) { console.error(e); } });

    async function loadAll() {
      const { data, error } = await sb.from("docs").select("coll,id,data");
      if (error) throw error;
      cache.clear();
      for (const r of data) cache.set(key(r.coll, r.id), r.data || {});
      emit();
    }
    await loadAll();

    // Live sync: apply each change straight from the realtime payload.
    sb.channel("docs-sync")
      .on("postgres_changes", { event: "*", schema: "public", table: "docs" }, p => {
        if (p.eventType === "DELETE") { if (p.old?.coll) cache.delete(key(p.old.coll, p.old.id)); }
        else if (p.new?.coll) cache.set(key(p.new.coll, p.new.id), p.new.data || {});
        emit();
      })
      .subscribe(status => { if (status === "SUBSCRIBED") loadAll().catch(() => {}); });
    // Safety net if a realtime event is missed (laptop sleep, flaky Wi-Fi).
    document.addEventListener("visibilitychange", () => { if (!document.hidden) loadAll().catch(() => {}); });

    const fail = error => { if (error) { const e = new Error(error.message); e.code = error.code; throw e; } };
    const ref = (coll, id) => ({
      async update(patch) {
        cache.set(key(coll, id), merge(cache.get(key(coll, id)) || {}, patch)); emit();
        const { error } = await sb.rpc("patch_doc", { p_token: token, p_coll: coll, p_id: id, p_patch: patch });
        if (error) { await loadAll().catch(() => {}); fail(error); }
      },
      // The database only accepts merges through patch_doc (no direct writes, no deletes),
      // so set() merges too: callers always pass the same keys, which makes it a replace in practice.
      async set(data) {
        cache.set(key(coll, id), merge(cache.get(key(coll, id)) || {}, data)); emit();
        const { error } = await sb.rpc("patch_doc", { p_token: token, p_coll: coll, p_id: id, p_patch: data });
        if (error) { await loadAll().catch(() => {}); fail(error); }
      },
      onSnapshot(cb) {
        const fn = () => { const d = cache.get(key(coll, id)); cb({ exists: d !== undefined, data: () => d }); };
        listeners.add(fn); fn();
        return () => listeners.delete(fn);
      },
    });

    return {
      // Server-side function (e.g. deathroll_roll). If it returns a doc's new data, show it right away.
      async call(fn, args, coll, id) {
        const { data, error } = await sb.rpc(fn, args);
        if (error) fail(error);
        if (coll && id && data && typeof data === "object") { cache.set(key(coll, id), data); emit(); }
        return data;
      },
      doc(path) { const [c, i] = path.split("/"); return ref(c, i); },
      collection(coll) {
        return {
          doc: id => ref(coll, id),
          async add(data) { const id = (coll === "players" ? "p_" : "") + rid().slice(0, 12); await ref(coll, id).set(data); return { id }; },
          onSnapshot(cb) {
            const fn = () => {
              const docs = [];
              for (const [k, d] of cache) if (k.startsWith(coll + "/")) docs.push({ id: k.slice(coll.length + 1), data: () => d });
              cb({ docs });
            };
            listeners.add(fn); fn();
            return () => listeners.delete(fn);
          },
        };
      },
      // Who has the site open right now (Supabase Realtime presence, nothing stored). One entry per browser tab.
      presence(onChange) {
        let meta = { player: "" };
        const ch = sb.channel("online", { config: { presence: { key: browserId() + "-" + rid().slice(0, 6) } } });
        ch.on("presence", { event: "sync" }, () => onChange(Object.values(ch.presenceState()).flat()))
          .subscribe(st => { if (st === "SUBSCRIBED") ch.track(meta).catch(() => {}); });
        return { set(m) { meta = m; ch.track(meta).catch(() => {}); } };
      },
    };
  }

  window.WFStore = {
    db: () => createDb().catch(e => { console.error("Supabase:", e); return null; }),
    userId: browserId,
    setToken: t => { token = t || ""; },
  };
})();
