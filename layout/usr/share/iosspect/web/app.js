/* =============================================================================
   IOSspect dashboard controller.
   - Sidebar app picker (always visible)
   - Tab routing in main area
   - Keyboard: 1-9 jump tabs, / focus search, T toggle theme
   ============================================================================= */
(() => {

const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

const fmt = {
    bytes(b) {
        if (b == null || b < 0) return '-';
        const u = ['B','KB','MB','GB','TB']; let i = 0, v = b;
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return `${v < 10 && i ? v.toFixed(1) : Math.round(v)} ${u[i]}`;
    },
    esc(s) { return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
};

// ============== Auth ==============
// Password + session cookie. The cookie is HttpOnly so JS never sees
// it; the browser ships it automatically with every request.

async function explainError(r) {
    let body = '';
    try { body = await r.text(); } catch (_) {}
    let msg = `HTTP ${r.status}`;
    if (body) {
        try { const j = JSON.parse(body); if (j.error) msg = j.error; } catch (_) { msg += ` ${body.slice(0, 160)}`; }
    }
    const e = new Error(msg); e.status = r.status; return e;
}

async function fetchAuthed(url, init = {}) {
    const merged = Object.assign({ credentials: 'same-origin' }, init);
    let r = await fetch(url, merged);
    if (r.status === 401) {
        // Session expired or never authed. Show login overlay; on success retry once.
        if (await showLoginOverlay()) {
            r = await fetch(url, merged);
        }
    }
    return r;
}

const api = {
    async get(url, opts) {
        const r = await fetchAuthed(url, opts);
        if (!r.ok) throw await explainError(r);
        const ct = r.headers.get('content-type') || '';
        return ct.includes('json') ? r.json() : r.text();
    },
    async post(url, body, opts) {
        const r = await fetchAuthed(url, Object.assign({
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: body ? JSON.stringify(body) : undefined
        }, opts || {}));
        if (!r.ok) throw await explainError(r);
        return r.json();
    },
    async blob(url, opts) {
        const r = await fetchAuthed(url, opts);
        if (!r.ok) throw await explainError(r);
        return r.blob();
    }
};

// Stream `url` into memory with progress updates, then save with the
// given filename. Routes the download through fetch + blob:URL instead
// of Chrome's download manager, which otherwise rejects with "Network
// error" because its TLS path enforces stricter cert checks than the
// page context that already accepted the self-signed cert.
//
// The progress reporter is critical for >50 MB transfers. Over WiFi a
// 130 MB bundle takes ~60s and without feedback the toast looks stuck.
async function downloadBlob(url, filename) {
    const baseLabel = `Downloading ${filename}`;
    const t0 = performance.now();
    let toastId;
    try {
        toastId = toast(`${baseLabel} ... 0 MB`, 'ok', 60_000);
        const r = await fetchAuthed(url);
        if (!r.ok) {
            const err = await explainError(r);
            toast(`Download failed: ${err.message || r.status}`, 'err');
            return;
        }
        const total = Number(r.headers.get('Content-Length') || 0);
        const chunks = [];
        let received = 0;
        const reader = r.body.getReader();
        let lastTick = 0;
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            chunks.push(value);
            received += value.length;
            const now = performance.now();
            if (now - lastTick > 250) {
                lastTick = now;
                const pct = total ? ` (${Math.round(100 * received / total)}%)` : '';
                updateToast(toastId, `${baseLabel} ... ${fmt.bytes(received)}${pct}`);
            }
        }
        const blob = new Blob(chunks, { type: r.headers.get('Content-Type') || 'application/octet-stream' });
        const obj = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = obj; a.download = filename;
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(obj), 5000);
        const secs = ((performance.now() - t0) / 1000).toFixed(1);
        updateToast(toastId, `Downloaded ${filename} (${fmt.bytes(received)}, ${secs}s)`, 'ok', 4000);
    } catch (e) {
        if (toastId) updateToast(toastId, `Download failed: ${e.message}`, 'err', 5000);
        else toast(`Download failed: ${e.message}`, 'err');
    }
}

// Render a modal login overlay. Returns a promise that resolves true on
// successful login.
//
// Concurrency: when several `api.*` calls fire in parallel and all get
// 401 (typical SPA-boot case), each one calls showLoginOverlay(). The
// dedup token must be set BEFORE the overlay is appended; setting it
// inside the Promise executor where `p` is still undefined lets six
// password fields stack up in the DOM.
function showLoginOverlay() {
    if (window.__iosspect_loginPromise) return window.__iosspect_loginPromise;

    let resolveOuter;
    const p = new Promise(resolve => { resolveOuter = resolve; });
    window.__iosspect_loginPromise = p;

    const veil = document.createElement('div');
    veil.className = 'login-veil';
    veil.innerHTML = `
        <form class="login-card" autocomplete="off">
            <div class="login-brand">
                <svg viewBox="0 0 36 36" width="22" height="22" fill="none">
                    <rect x="3" y="3" width="30" height="30" rx="8.5" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"/>
                    <circle cx="18" cy="18" r="6.2" fill="none" stroke="var(--accent)" stroke-width="2.4"/>
                    <circle cx="18" cy="18" r="2.4" fill="var(--accent)"/>
                </svg>
                <span><b>IOS</b>spect</span>
            </div>
            <h3>Sign in</h3>
            <p class="muted small">Enter the password shown in the IOSspect app on your phone.<br>
            The password can only be changed from inside the app.</p>
            <div style="position:relative">
                <input type="password" id="login-pw" class="input mono" placeholder="password" autofocus required style="padding-right:36px;width:100%">
                <button type="button" id="login-pw-eye" tabindex="-1" aria-label="Show password"
                        style="position:absolute;right:6px;top:50%;transform:translateY(-50%);background:transparent;border:0;cursor:pointer;color:var(--muted);font-size:16px;padding:4px 8px">👁</button>
            </div>
            <button type="submit" class="btn">Sign in</button>
            <div id="login-err" class="muted small" style="color:var(--red);min-height:14px"></div>
        </form>`;
    document.body.appendChild(veil);

    const form = veil.querySelector('form');
    const pwInput = veil.querySelector('#login-pw');
    const err = veil.querySelector('#login-err');
    const eyeBtn = veil.querySelector('#login-pw-eye');
    if (eyeBtn) {
        eyeBtn.addEventListener('click', () => {
            const showing = pwInput.type === 'text';
            pwInput.type = showing ? 'password' : 'text';
            eyeBtn.textContent = showing ? '👁' : '🙈';
            pwInput.focus();
        });
    }
    form.addEventListener('submit', async e => {
        e.preventDefault();
        err.textContent = '';
        try {
            const r = await fetch('/api/auth/login', {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ password: pwInput.value })
            });
            if (r.ok) {
                veil.remove();
                window.__iosspect_loginPromise = null;
                resolveOuter(true);
            } else {
                err.textContent = r.status === 429
                    ? 'Too many attempts. Try again in a minute.'
                    : 'Wrong password.';
                pwInput.select();
            }
        } catch (ex) { err.textContent = ex.message; }
    });
    return p;
}

const S = {
    appList: [],
    pkg: null,            // currently selected package
    appInfo: null,        // currently selected app metadata
    tab: 'welcome',
    sqlitePath: null,
    filesRel: '',
    initialized: {},
    // Per-tab wiring guard. `S.initialized` gets cleared on every app
    // switch so the tab refetches its data, but static DOM listeners
    // must only register ONCE. Without this guard each app switch
    // stacks another click listener on #files-list; a single click on
    // a folder then fires the handler twice and produces paths like
    // `databases/databases/code_cache/code_cache` (the second handler
    // reads S.filesRel that the first had just optimistically updated).
    wired: new Set(),
    // AbortControllers for the currently in-flight file/preview fetches so
    // that a fast follow-up click cancels the slow one in flight instead of
    // being dropped or stacking behind it (the old behaviour made the file
    // browser feel frozen).
    filesAbort: null,
    previewAbort: null,
    theme: localStorage.getItem('iosspect.theme') || 'dark'
};

/**
 * Run [fn] exactly once for [key]. Used inside each tab's init function to
 * register static DOM listeners (and any other one-shot setup) so the
 * data-refresh side of init can be called freely on every app switch
 * without leaking listeners.
 */
function once(key, fn) {
    if (S.wired.has(key)) return;
    S.wired.add(key);
    fn();
}

function toast(msg, kind = '', ttl = 3500) {
    const t = document.createElement('div');
    t.className = 'toast ' + kind;
    t.textContent = msg;
    $('#toast').appendChild(t);
    if (ttl > 0) scheduleToastFade(t, ttl);
    return t;
}
// Replace a toast's text in place. Used by long-running downloads so
// the progress reading doesn't spawn a new toast every 250 ms. Passing
// `ttl` resets the auto-dismiss timer (e.g. once the download finishes
// we want the success toast to fade quickly).
function updateToast(node, msg, kind, ttl) {
    if (!node) return;
    node.textContent = msg;
    if (kind !== undefined) node.className = 'toast ' + kind;
    if (ttl !== undefined) {
        if (node._fadeTimer) clearTimeout(node._fadeTimer);
        scheduleToastFade(node, ttl);
    }
}
function scheduleToastFade(t, ttl) {
    t._fadeTimer = setTimeout(() => { t.style.opacity = 0; setTimeout(() => t.remove(), 300); }, ttl);
}

// ============== Theme ==============
function applyTheme(t) {
    document.documentElement.dataset.theme = t;
    S.theme = t;
    localStorage.setItem('iosspect.theme', t);
}
$('#themeToggle').onclick = () => applyTheme(S.theme === 'dark' ? 'light' : 'dark');
applyTheme(S.theme);

// ============== Tabs ==============
function showTab(name) {
    S.tab = name;
    $$('.panel').forEach(p => p.classList.toggle('hidden', p.dataset.tab !== name));
    $$('.tab').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
    if (!S.initialized[name]) {
        try { initTab(name); S.initialized[name] = true; } catch (e) { console.error(e); }
    } else {
        try { refreshTab(name); } catch (e) { console.error(e); }
    }
}

// Tab clicks can come from EITHER the sidebar nav (LIVE/ACT) OR the
// horizontal #main-tabs strip (Files/Manifest/Components/Native). Delegate
// from document so both work without needing two listeners.
document.addEventListener('click', e => {
    const t = e.target.closest('.tab');
    if (t && t.dataset.tab) showTab(t.dataset.tab);
});

// welcome panel "jump to" links
document.addEventListener('click', e => {
    const j = e.target.closest('[data-tab-jump]');
    if (j) { e.preventDefault(); showTab(j.dataset.tabJump); }
});

// keyboard shortcuts
document.addEventListener('keydown', e => {
    if (e.target.matches('input, textarea, [contenteditable]')) {
        if (e.key === 'Escape') e.target.blur();
        return;
    }
    if (e.key === '/') { e.preventDefault(); $('#app-search').focus(); return; }
    if (e.key === 't' || e.key === 'T') { applyTheme(S.theme === 'dark' ? 'light' : 'dark'); return; }
    const tabs = ['files','native','processes','net','logcat','shell'];
    const idx = parseInt(e.key, 10);
    if (idx >= 1 && idx <= 9 && tabs[idx - 1]) { showTab(tabs[idx - 1]); }
});

// ============== Header status pills ==============
async function refreshStatus() {
    try {
        const s = await api.get('/api/status');
        const rp = $('#root-pill');
        rp.classList.toggle('ok', !!s.rootAvailable);
        rp.classList.toggle('bad', !s.rootAvailable);
        // Don't render "root: root" when shell IS root: the prefix is
        // redundant. Only show the user name when it's something else.
        const label = !s.rootAvailable
            ? 'no root'
            : (s.shellUser && s.shellUser !== 'root' ? `root · ${s.shellUser}` : 'jailbroken');
        rp.innerHTML = `<span class="dot"></span>${fmt.esc(label)}`;
        $('#dev-pill').textContent = `${s.device.model} · iOS ${s.device.sdk}`;
    } catch (e) {
        $('#root-pill').innerHTML = '<span class="dot"></span>offline';
        $('#root-pill').classList.add('bad');
        $('#dev-pill').textContent = '-';
    }
}
refreshStatus();
setInterval(refreshStatus, 5000);

// ============== Sidebar: app list ==============
// We always fetch the installed apps AND the running process list, then mark
// rows green if a process exists. That way a pentester can tell at a glance
// which targets are alive (worth auditing live state) vs dormant (cold storage).
const S_runningPkgs = new Set();

async function loadRunningPkgs() {
    try {
        const r = await api.get('/api/live/processes');
        S_runningPkgs.clear();
        (r.processes || []).forEach(p => (p.packages || []).forEach(pk => S_runningPkgs.add(pk)));
    } catch (_) { /* leave whatever we had before */ }
}

async function loadApps() {
    const q = $('#app-search').value.trim().toLowerCase();
    const sys = $('#app-system').checked ? '1' : '0';
    const onlyRunning = $('#app-running')?.checked === true;
    try {
        // Refresh running set in parallel with the app listing.
        const [apps, _] = await Promise.all([
            api.get(`/api/apps?system=${sys}` + (q ? `&q=${encodeURIComponent(q)}` : '')),
            loadRunningPkgs()
        ]);
        const filtered = onlyRunning ? apps.filter(a => S_runningPkgs.has(a.packageName)) : apps;
        S.appList = filtered;
        const runCount = apps.filter(a => S_runningPkgs.has(a.packageName)).length;
        $('#apps-count').textContent = `${filtered.length} app${filtered.length === 1 ? '' : 's'} · ${runCount} running`;
        renderAppList(filtered);
    } catch (e) { toast(e.message, 'err'); }
}

function renderAppList(apps) {
    const root = $('#app-list');
    if (!apps.length) {
        root.innerHTML = '<div class="empty small">no apps</div>';
        return;
    }
    root.innerHTML = apps.map(a => {
        const isRunning = S_runningPkgs.has(a.packageName);
        // Compact: name + tiny inline status chips on row 1, mono pkg name
        // on row 2. Verbose "v1.x · SDK X" badges go to a hover-only title
        // tooltip to keep the row to two lines.
        const title = `v${fmt.esc(a.versionName || a.versionCode)} · SDK ${a.targetSdk}${a.debuggable ? ' · debuggable' : ''}`;
        return `
        <div class="app-row${S.pkg === a.packageName ? ' active' : ''}" data-pkg="${fmt.esc(a.packageName)}" role="listitem" title="${title}">
            <div class="name">
                ${isRunning ? '<span class="run-dot" title="Process is running"></span>' : '<span class="run-dot off" title="Not running"></span>'}
                <span class="lbl">${fmt.esc(a.label)}</span>
                ${a.debuggable ? '<span class="tg warn">debug</span>' : ''}
            </div>
            <div class="pkg">${fmt.esc(a.packageName)}</div>
        </div>`;
    }).join('');
}

$('#app-list').addEventListener('click', e => {
    const row = e.target.closest('.app-row');
    if (!row) return;
    selectPkg(row.dataset.pkg);
});

function selectPkg(pkg) {
    S.pkg = pkg;
    S.appInfo = S.appList.find(a => a.packageName === pkg) || null;
    S.filesRel = '';
    S.sqlitePath = null;
    // every per-app tab needs a fresh load
    ['files','prefs','sqlite','manifest','components','native'].forEach(t => delete S.initialized[t]);
    renderAppList(S.appList);
    renderSelectedApp();
    if (S.tab === 'welcome' || ['processes','net','logcat','shell'].includes(S.tab)) {
        showTab('files');
    } else {
        showTab(S.tab); // re-render with new pkg
    }
}

function renderSelectedApp() {
    const el = $('#selected-app');
    const actionsBlock = $('#sb-actions');
    const inspectTabs  = $('#main-tabs');
    if (!S.appInfo) {
        el.innerHTML = '<span class="muted small">Pick an app on the left to start.</span>';
        // Hide everything that needs an app context: action icons in the
        // sidebar + the per-app inspection tabs above the panels.
        if (actionsBlock) actionsBlock.hidden = true;
        if (inspectTabs)  inspectTabs.hidden  = true;
        return;
    }
    const a = S.appInfo;
    el.innerHTML = `
        <span class="label">${fmt.esc(a.label)}</span>
        <span class="pkg">${fmt.esc(a.packageName)}</span>
        <span class="ver">v${fmt.esc(a.versionName)} · SDK ${a.targetSdk} · uid ${a.uid}${a.debuggable ? ' · debuggable' : ''}</span>
    `;
    if (actionsBlock) actionsBlock.hidden = false;
    if (inspectTabs)  inspectTabs.hidden  = false;
}

$('#app-search').addEventListener('input', debounce(loadApps, 200));
$('#app-system').onchange = loadApps;
$('#app-running')?.addEventListener('change', loadApps);
$('#app-refresh').onclick = loadApps;
// Periodically refresh the running set so the green dot reflects reality.
setInterval(() => { loadRunningPkgs().then(() => renderAppList(S.appList)); }, 8000);

// ============== App actions (sidebar grid) ==============
// Actions live in the sidebar now (under the selected app) but the handler
// stays event-delegated by [data-action] so the wiring is identical.
$('#sb-actions').addEventListener('click', async e => {
    const b = e.target.closest('[data-action]');
    if (!b || !S.pkg) { if (!S.pkg) toast('Pick an app first', 'err'); return; }
    const action = b.dataset.action;
    if (action === 'clear' && !confirm(`Wipe the data container for ${S.pkg}? This removes every file the app has written and cannot be undone.`)) return;

    if (action === 'pull-apk') {
        // downloadBlob owns its own progress toast.
        await downloadBlob(`/api/apps/${encodeURIComponent(S.pkg)}/apk`, `${S.pkg}.ipa`);
        return;
    }

    try {
        const r = await api.post(`/api/apps/${encodeURIComponent(S.pkg)}/actions/${action}`);
        toast(`${action} → ${r.ok ? 'ok' : 'failed'}` + (r.output ? ` - ${String(r.output).slice(0, 100)}` : ''), r.ok ? 'ok' : 'err');
    } catch (e) { toast(e.message, 'err'); }
});

// ============== FILES tab ==============
const iconFor = e => {
    if (e.isDir) return '📁';
    switch (e.kind) {
        case 'sqlite': return '🗄'; case 'prefs': return '⚙';
        case 'xml': return '📜';   case 'json': return '{}';
        case 'image': return '🖼';  case 'text': return '📄';
        case 'html': return '🌐';  case 'code': return '<>';
        case 'native': return 'ʚ'; case 'apk': return '📦';
        default: return '·';
    }
};
async function loadFiles(rel = '') {
    if (!S.pkg) return;
    // Cancel any in-flight nav so a second click during a slow fetch
    // doesn't appear to freeze the UI. The first request is aborted
    // and a fresh fetch starts immediately.
    if (S.filesAbort) { try { S.filesAbort.abort(); } catch (_) {} }
    const ctrl = new AbortController();
    S.filesAbort = ctrl;

    const prevRel = S.filesRel;
    S.filesRel = rel;
    // Visual hint while the fetch is in flight: keep the existing
    // rows visible (so the user knows the click landed) but dim them.
    const list = $('#files-list');
    if (list) list.classList.add('loading');
    // Clear stale preview when changing directory.
    if (rel !== prevRel) { const pv = $('#files-preview'); if (pv) pv.innerHTML = '<div class="empty">Select a file to preview.</div>'; }
    try {
        const data = await api.get(
            `/api/apps/${encodeURIComponent(S.pkg)}/files?path=${encodeURIComponent(rel)}`,
            { signal: ctrl.signal }
        );
        // Bail if a newer nav already kicked off. Stale results must
        // not overwrite the current list.
        if (S.filesAbort !== ctrl) return;
        renderCrumb(data.relative);
        if (!data.entries.length) { list.innerHTML = '<div class="empty small">empty</div>'; return; }
        list.innerHTML = data.entries.map(e => `
            <div class="row" data-name="${fmt.esc(e.name)}" data-dir="${e.isDir}" data-kind="${e.kind}">
                <span class="icon">${iconFor(e)}</span>
                <span class="name">${fmt.esc(e.name)}</span>
                <span class="meta">${e.isDir ? '' : fmt.bytes(e.size)}</span>
            </div>
        `).join('');
    } catch (e) {
        if (e.name === 'AbortError') return; // superseded by newer click
        // Roll back so a typo'd path doesn't poison subsequent navigations.
        S.filesRel = prevRel;
        if (list) list.innerHTML = `<div class="empty" style="color: var(--red)">${fmt.esc(e.message)}</div>`;
    } finally {
        if (S.filesAbort === ctrl) S.filesAbort = null;
        if (list) list.classList.remove('loading');
    }
}
function renderCrumb(rel) {
    const parts = rel.split('/').filter(Boolean);
    const html = [`<a data-path="">/data/data/${fmt.esc(S.pkg)}</a>`];
    let acc = '';
    parts.forEach(p => { acc = acc ? `${acc}/${p}` : p; html.push('<span class="sep">/</span>', `<a data-path="${fmt.esc(acc)}">${fmt.esc(p)}</a>`); });
    $('#files-crumb').innerHTML = html.join('');
}
async function previewFile(name, kind) {
    const rel = S.filesRel ? `${S.filesRel}/${name}` : name;
    const enc = encodeURIComponent;
    const base = `/api/apps/${enc(S.pkg)}/files`;
    const p = $('#files-preview');
    const dlUrl = `${base}/raw?path=${enc(rel)}&download=1`;
    const header = `
        <div class="toolbar" style="margin-bottom:8px">
            <span class="muted small mono">${fmt.esc(rel)}</span>
            <span class="grow"></span>
            <a class="btn ghost small" href="${dlUrl}" download="${fmt.esc(name)}" title="Download">⤓ Download</a>
        </div>`;
    p.innerHTML = header + '<div class="empty">loading...</div>';
    // Cancel a previous preview that's still streaming so rapid clicks
    // through a directory don't queue up.
    if (S.previewAbort) { try { S.previewAbort.abort(); } catch (_) {} }
    const ctrl = new AbortController();
    S.previewAbort = ctrl;
    const stale = () => S.previewAbort !== ctrl;
    try {
        if (kind === 'image') {
            // Go through /files/image which re-encodes server-side as PNG
            // via UIImage. Lets us preview .ktx app snapshots (iOS-only
            // format the browser can't decode) alongside PNG/JPEG/HEIC.
            const blob = await api.blob(`${base}/image?path=${enc(rel)}`, { signal: ctrl.signal });
            if (stale()) return;
            p.innerHTML = header + `<img class="preview-img" src="${URL.createObjectURL(blob)}" alt="${fmt.esc(name)}"/>`;
        } else if (kind === 'sqlite') {
            // .db / .sqlite: show a lightweight summary in the preview
            // pane (table list + row counts) plus a "Open in SQLite
            // Browser" button that hands off to the full query view.
            let summary;
            try {
                const data = await api.get(
                    `/api/apps/${enc(S.pkg)}/sqlite/tables?path=${enc(rel)}`,
                    { signal: ctrl.signal }
                );
                if (stale()) return;
                const tables = data.tables || [];
                summary = tables.length
                    ? `<div class="kv-list">${tables.slice(0, 50).map(t => `
                        <div class="kv"><div class="k mono">${fmt.esc(t.name)}</div><div class="v mono">${t.rowCount >= 0 ? t.rowCount + ' rows' : '?'}</div></div>
                       `).join('')}${tables.length > 50 ? `<div class="muted small">... and ${tables.length - 50} more</div>` : ''}</div>`
                    : '<div class="empty small">no tables</div>';
            } catch (e) {
                if (e.name === 'AbortError') return;
                summary = `<div class="empty" style="color: var(--red)">${fmt.esc(e.message)}</div>`;
            }
            const newHeader = `
                <div class="toolbar" style="margin-bottom:8px">
                    <span class="muted small mono">${fmt.esc(rel)}</span>
                    <span class="grow"></span>
                    <button class="btn small" id="open-sqlite-browser" title="Open the typed SQLite browser for this DB">🗄 Open in SQLite Browser</button>
                    <a class="btn ghost small" href="${dlUrl}" download="${fmt.esc(name)}" title="Download">⤓ Download</a>
                </div>`;
            p.innerHTML = newHeader + summary;
            const sb = $('#open-sqlite-browser');
            if (sb) sb.onclick = () => {
                $('#sqlite-path').value = rel;
                showTab('sqlite');
                openSqlite(rel);
            };
        } else if (kind === 'plist') {
            // Both binary (bplist00) and XML plists go through the same
            // PropertyListSerialization-backed endpoint. We render both
            // a typed key/value table and the pretty XML round-trip so
            // the user can copy paste raw if they want.
            const resp = await api.get(`${base}/plist?path=${enc(rel)}`, { signal: ctrl.signal });
            if (stale()) return;
            if (resp.error) {
                p.innerHTML = header + `<div class="empty" style="color: var(--red)">${fmt.esc(resp.error)}</div>`
                            + (resp.hex ? `<pre class="code-block">${fmt.esc(resp.hex)}</pre>` : '');
                return;
            }
            const tree = resp.tree || {};
            const xml  = resp.xml  || '';
            p.innerHTML = header
                + `<pre class="code-block">${fmt.esc(JSON.stringify(tree, null, 2))}</pre>`
                + (xml ? `<details style="margin-top:10px"><summary class="muted small">raw XML (${resp.size} bytes)</summary>
                          <pre class="code-block">${fmt.esc(xml)}</pre></details>` : '');
        } else if (['text','json','xml','prefs','html','code'].includes(kind)) {
            // SharedPreferences XML renders as a normal text file with
            // a header link to open it in the typed Prefs editor when
            // the user actually wants to change keys. The server marks
            // these as `xml` (not `prefs`), so detect by path prefix.
            const resp = await api.get(`${base}/text?path=${enc(rel)}`, { signal: ctrl.signal });
            if (stale()) return;
            // /files/text returns { path, text, size }; pluck text.
            const body = (resp && typeof resp === 'object') ? (resp.text ?? '') : String(resp);
            const isPrefs = kind === 'prefs' || (rel.startsWith('shared_prefs/') && rel.endsWith('.xml'));
            const editBtn = isPrefs
                ? `<button class="btn ghost small" id="open-prefs-editor" title="Open this XML in the typed Prefs editor">✎ Edit as Prefs</button>`
                : '';
            // Re-render the header with the optional Edit link.
            const newHeader = `
                <div class="toolbar" style="margin-bottom:8px">
                    <span class="muted small mono">${fmt.esc(rel)}</span>
                    <span class="grow"></span>
                    ${editBtn}
                    <a class="btn ghost small" href="${dlUrl}" download="${fmt.esc(name)}" title="Download">⤓ Download</a>
                </div>`;
            p.innerHTML = newHeader + `<pre class="code-block">${fmt.esc(body)}</pre>`;
            if (isPrefs) {
                const btn = $('#open-prefs-editor');
                if (btn) btn.onclick = async () => {
                    showTab('prefs');
                    if (typeof loadPrefs === 'function') await loadPrefs();
                };
            }
        } else {
            // Binary/audio/video/pdf/native: show a hex dump.
            const resp = await api.get(`${base}/hex?path=${enc(rel)}&limit=4096`, { signal: ctrl.signal });
            if (stale()) return;
            // /files/hex returns { path, hex, size }. Format the hex into
            // 16-byte rows so it's actually readable.
            const raw = (resp && typeof resp === 'object') ? (resp.hex ?? '') : String(resp);
            const bytes = raw.split(/\s+/).filter(Boolean);
            const rows = [];
            for (let i = 0; i < bytes.length; i += 16) {
                const chunk = bytes.slice(i, i + 16);
                const offset = i.toString(16).padStart(8, '0');
                const ascii = chunk.map(h => {
                    const b = parseInt(h, 16);
                    return (b >= 0x20 && b <= 0x7e) ? String.fromCharCode(b) : '.';
                }).join('');
                rows.push(`${offset}  ${chunk.join(' ').padEnd(48, ' ')}  ${ascii}`);
            }
            p.innerHTML = header + `<pre class="code-block">${fmt.esc(rows.join('\n'))}</pre>`;
        }
    } catch (e) {
        if (e.name === 'AbortError') return;
        p.innerHTML = header + `<div class="empty" style="color: var(--red)">${fmt.esc(e.message)}</div>`;
    } finally {
        if (S.previewAbort === ctrl) S.previewAbort = null;
    }
}

// Trigger a download of the current dir as a ZIP. The server streams the zip,
// so for huge dirs the browser shows progress in its native download UI.
function downloadCurrentDirZip() {
    if (!S.pkg) { toast('Pick an app first', 'err'); return; }
    const url = `/api/apps/${encodeURIComponent(S.pkg)}/files/zip?path=${encodeURIComponent(S.filesRel)}`;
    const name = `${S.pkg}${S.filesRel ? '_' + S.filesRel.replace(/\//g, '_') : ''}.zip`;
    downloadBlob(url, name);
}

// Content-search the current dir recursively.
async function grepCurrentDir() {
    if (!S.pkg) { toast('Pick an app first', 'err'); return; }
    const q = $('#files-grep').value.trim();
    if (!q) { toast('Enter a pattern to grep', 'err'); $('#files-grep').focus(); return; }
    const p = $('#files-preview');
    p.innerHTML = `<div class="empty">searching for "${fmt.esc(q)}" under <code>${fmt.esc(S.filesRel || '/')}</code> ...</div>`;
    try {
        const url = `/api/apps/${encodeURIComponent(S.pkg)}/files/grep?path=${encodeURIComponent(S.filesRel)}&q=${encodeURIComponent(q)}&limit=200`;
        const r = await api.get(url);
        if (!r.hits || !r.hits.length) {
            p.innerHTML = `<div class="empty">no matches for "${fmt.esc(q)}"</div>`;
            return;
        }
        p.innerHTML = `
            <div class="toolbar" style="margin-bottom:8px">
                <span class="muted small">${r.total} hit${r.total === 1 ? '' : 's'} for <code>${fmt.esc(q)}</code> under <code>${fmt.esc(r.root)}</code></span>
            </div>
            ${r.hits.map(h => `
                <div class="component-row" style="cursor:pointer" data-rel="${fmt.esc(h.relative)}">
                    <div class="component-name mono">${fmt.esc(h.relative)}</div>
                    <div class="component-filters mono" style="white-space:pre-wrap">${fmt.esc(h.sample)}</div>
                </div>
            `).join('')}
        `;
        p.addEventListener('click', e => {
            const row = e.target.closest('[data-rel]'); if (!row) return;
            const fullRel = row.dataset.rel;
            // Open the file content view via existing previewFile flow.
            const parts = fullRel.split('/');
            const name = parts.pop();
            S.filesRel = parts.join('/');
            // Determine kind from extension
            const ext = (name.split('.').pop() || '').toLowerCase();
            const kind = ['png','jpg','jpeg','webp','gif'].includes(ext) ? 'image'
                       : ['db','sqlite','sqlite3','db3'].includes(ext) ? 'sqlite'
                       : ['xml','json','txt','log','csv','html','htm','js','css','yml','yaml'].includes(ext) ? 'text'
                       : 'binary';
            loadFiles(S.filesRel).then(() => previewFile(name, kind));
        }, { once: true });
    } catch (e) {
        p.innerHTML = `<div class="empty" style="color: var(--red)">${fmt.esc(e.message)}</div>`;
    }
}
function initFiles() {
    once('files', () => {
        $('#files-list').addEventListener('click', e => {
            const r = e.target.closest('.row'); if (!r) return;
            $$('.row', $('#files-list')).forEach(x => x.classList.remove('active'));
            r.classList.add('active');
            if (r.dataset.dir === 'true') loadFiles(S.filesRel ? `${S.filesRel}/${r.dataset.name}` : r.dataset.name);
            else previewFile(r.dataset.name, r.dataset.kind);
        });
        $('#files-crumb').addEventListener('click', e => {
            const a = e.target.closest('a[data-path]'); if (a) loadFiles(a.dataset.path);
        });
        $('#files-up').onclick = () => { if (S.filesRel) loadFiles(S.filesRel.split('/').slice(0, -1).join('/')); };
        $('#files-zip').onclick = downloadCurrentDirZip;
        $('#files-grep-btn').onclick = grepCurrentDir;
        $('#files-grep').addEventListener('keydown', e => { if (e.key === 'Enter') grepCurrentDir(); });
    });
    loadFiles('');
}
function refreshFiles() { if (S.pkg) loadFiles(S.filesRel); }

// ============== PREFS tab ==============
async function loadPrefs() {
    if (!S.pkg) return;
    try {
        const data = await api.get(`/api/apps/${encodeURIComponent(S.pkg)}/prefs`);
        const root = $('#prefs-list');
        if (!data.buckets.length) { root.innerHTML = '<div class="empty">No shared_prefs found.</div>'; return; }
        root.innerHTML = data.buckets.map(b => `
            <div class="pref-bucket" data-bucket="${fmt.esc(b.name)}">
                <h3>
                    <span>${fmt.esc(b.name)}.xml <span class="muted small">· ${b.entries.length} entries</span></span>
                    <button class="btn ghost small" data-action="add-pref" title="Add a new key">＋ key</button>
                </h3>
                ${b.entries.map(e => prefRowHtml(b.name, e)).join('')}
            </div>
        `).join('');
    } catch (e) { toast(e.message, 'err'); }
}

function prefRowHtml(bucket, e) {
    const typeTag = e.type === 'STRING' ? '' : `<span class="tg cyan tiny">${e.type.toLowerCase()}</span>`;
    return `
        <div class="pref-row" data-bucket="${fmt.esc(bucket)}" data-key="${fmt.esc(e.key)}" data-type="${e.type}">
            <div class="key">${fmt.esc(e.key)} ${typeTag}</div>
            <div class="val" data-role="val-cell">
                <span class="val-text">${fmt.esc(e.value)}</span>
                <span class="pref-actions">
                    <button class="link-btn" data-action="edit-pref" title="Edit value (force-stops the app)">✎</button>
                    <button class="link-btn" data-action="delete-pref" title="Delete this key (force-stops the app)">🗑</button>
                </span>
            </div>
        </div>`;
}

function enterEdit(row) {
    const valCell = row.querySelector('[data-role="val-cell"]');
    const current = row.querySelector('.val-text').textContent;
    const type = row.dataset.type;
    let inputHtml;
    if (type === 'BOOLEAN') {
        inputHtml = `<select class="input mono small" data-role="val-input">
            <option value="true"${current === 'true' ? ' selected' : ''}>true</option>
            <option value="false"${current === 'false' ? ' selected' : ''}>false</option>
        </select>`;
    } else {
        const inputType = (type === 'INT' || type === 'LONG' || type === 'FLOAT') ? 'number' : 'text';
        inputHtml = `<input class="input mono" data-role="val-input" type="${inputType}" value="${fmt.esc(current)}">`;
    }
    valCell.innerHTML = `${inputHtml}
        <span class="pref-actions">
            <button class="link-btn" data-action="save-pref" title="Save (force-stops the app)">💾</button>
            <button class="link-btn" data-action="cancel-pref" title="Cancel">✕</button>
        </span>`;
    valCell.querySelector('[data-role="val-input"]').focus();
}

async function savePref(row) {
    const bucket = row.dataset.bucket;
    const key = row.dataset.key;
    const type = row.dataset.type;
    const input = row.querySelector('[data-role="val-input"]');
    if (!input) return;
    const value = input.value;
    try {
        const r = await api.post(`/api/apps/${encodeURIComponent(S.pkg)}/prefs/set`, {
            bucket, key, value, type, forceStop: true
        });
        if (!r.ok) throw new Error(r.error || 'write failed');
        toast(`${bucket}.xml · ${key} = ${value} (app force-stopped)`, 'ok');
        await loadPrefs();
    } catch (e) { toast(e.message, 'err'); }
}

async function deletePref(row) {
    const bucket = row.dataset.bucket;
    const key = row.dataset.key;
    if (!confirm(`Delete "${key}" from ${bucket}.xml?\n\nThe app will be force-stopped first so it picks up the change on next launch.`)) return;
    try {
        const r = await api.post(`/api/apps/${encodeURIComponent(S.pkg)}/prefs/set`, {
            bucket, key, value: null, forceStop: true
        });
        if (!r.ok) throw new Error(r.error || 'delete failed');
        toast(`Deleted ${key} from ${bucket}.xml`, 'ok');
        await loadPrefs();
    } catch (e) { toast(e.message, 'err'); }
}

async function addPref(bucketEl) {
    const bucket = bucketEl.dataset.bucket;
    const key = prompt(`New key in ${bucket}.xml:`);
    if (!key) return;
    const type = prompt('Type: string / int / long / float / boolean', 'string')?.toLowerCase() || 'string';
    const value = prompt(`Value (${type}):`, type === 'boolean' ? 'true' : '');
    if (value === null) return;
    try {
        const r = await api.post(`/api/apps/${encodeURIComponent(S.pkg)}/prefs/set`, {
            bucket, key, value, type, forceStop: true
        });
        if (!r.ok) throw new Error(r.error || 'write failed');
        toast(`Added ${key} = ${value} to ${bucket}.xml`, 'ok');
        await loadPrefs();
    } catch (e) { toast(e.message, 'err'); }
}

function initPrefs() {
    once('prefs', () => {
        $('#prefs-refresh').onclick = loadPrefs;
        $('#prefs-list').addEventListener('click', e => {
            const btn = e.target.closest('[data-action]');
            if (!btn) return;
            const row = e.target.closest('.pref-row');
            switch (btn.dataset.action) {
                case 'edit-pref':   if (row) enterEdit(row); break;
                case 'save-pref':   if (row) savePref(row); break;
                case 'cancel-pref': loadPrefs(); break;
                case 'delete-pref': if (row) deletePref(row); break;
                case 'add-pref':    addPref(e.target.closest('.pref-bucket')); break;
            }
        });
        $('#prefs-list').addEventListener('keydown', e => {
            if (e.key === 'Enter' && e.target.matches('[data-role="val-input"]')) {
                const row = e.target.closest('.pref-row'); if (row) savePref(row);
            } else if (e.key === 'Escape' && e.target.matches('[data-role="val-input"]')) {
                loadPrefs();
            }
        });
    });
    loadPrefs();
}
function refreshPrefs() { if (S.pkg) loadPrefs(); }

// ============== SQLITE tab ==============
async function openSqlite(path) {
    S.sqlitePath = path || $('#sqlite-path').value.trim();
    if (!S.pkg || !S.sqlitePath) return;
    try {
        const data = await api.get(`/api/apps/${encodeURIComponent(S.pkg)}/sqlite/tables?path=${encodeURIComponent(S.sqlitePath)}`);
        $('#sqlite-tables').innerHTML = data.tables.map(t => `
            <div class="row" data-table="${fmt.esc(t.name)}">
                <span class="icon">🗄</span>
                <span class="name">${fmt.esc(t.name)}</span>
                <span class="meta">${t.rowCount >= 0 ? t.rowCount : '?'}</span>
            </div>
        `).join('') || '<div class="empty small">no tables</div>';
    } catch (e) { $('#sqlite-tables').innerHTML = `<div class="empty" style="color: var(--red)">${fmt.esc(e.message)}</div>`; }
}
async function loadTable(table) {
    try {
        const data = await api.get(`/api/apps/${encodeURIComponent(S.pkg)}/sqlite/rows?path=${encodeURIComponent(S.sqlitePath)}&table=${encodeURIComponent(table)}&limit=200&offset=0`);
        renderTable($('#sqlite-result'), data);
    } catch (e) { toast(e.message, 'err'); }
}
async function runQuery() {
    const sql = $('#sqlite-query').value.trim(); if (!sql) return;
    try {
        const data = await api.post(`/api/apps/${encodeURIComponent(S.pkg)}/sqlite/query`, { path: S.sqlitePath, sql, limit: 500 });
        renderTable($('#sqlite-result'), data);
    } catch (e) { $('#sqlite-result').innerHTML = `<div class="empty" style="color: var(--red)">${fmt.esc(e.message)}</div>`; }
}
function renderTable(root, data) {
    if (!data.columns) { root.innerHTML = '<div class="empty">no data</div>'; return; }
    const head = data.columns.map(c => `<th>${fmt.esc(c)}</th>`).join('');
    const body = data.rows.map(row => '<tr>' + row.map(v => v === null ? '<td class="null">NULL</td>' : `<td>${fmt.esc(v)}</td>`).join('') + '</tr>').join('');
    root.innerHTML = `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>
        <div class="muted small" style="padding: 6px 12px; border-top: 1px solid var(--line)">
            ${data.rows.length} of ${data.total} rows · offset ${data.offset} · limit ${data.limit}
        </div>`;
}
function initSqlite() {
    once('sqlite', () => {
        $('#sqlite-back').onclick = () => showTab('files');
        $('#sqlite-open').onclick = () => openSqlite();
        $('#sqlite-run').onclick = runQuery;
        $('#sqlite-query').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) runQuery(); });
        $('#sqlite-tables').addEventListener('click', e => {
            const r = e.target.closest('.row'); if (!r) return;
            $$('.row', $('#sqlite-tables')).forEach(x => x.classList.remove('active'));
            r.classList.add('active');
            S.sqliteCurrentTable = r.dataset.table;
            loadTable(r.dataset.table);
        });
        $('#sqlite-download').onclick = () => {
            if (!S.pkg || !S.sqlitePath) { toast('Open a DB first', 'err'); return; }
            const url = `/api/apps/${encodeURIComponent(S.pkg)}/sqlite/download?path=${encodeURIComponent(S.sqlitePath)}`;
            const name = S.sqlitePath.split('/').pop() || 'database.db';
            downloadBlob(url, name);
        };
        $('#sqlite-csv').onclick = async () => {
            if (!S.pkg || !S.sqlitePath) { toast('Open a DB first', 'err'); return; }
            const sql = $('#sqlite-query').value.trim();
            const body = sql ? { path: S.sqlitePath, sql, limit: 10000 }
                             : { path: S.sqlitePath, table: S.sqliteCurrentTable, limit: 10000 };
            if (!body.sql && !body.table) { toast('Run a query or select a table first', 'err'); return; }
            // Use fetch directly since we want the file as a blob to trigger download.
            try {
                const r = await fetch(`/api/apps/${encodeURIComponent(S.pkg)}/sqlite/csv`, {
                    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
                });
                if (!r.ok) throw await explainError(r);
                const blob = await r.blob();
                const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
                a.download = (body.table || 'query') + '.csv';
                document.body.appendChild(a); a.click(); a.remove();
                toast(`Downloaded ${a.download}`, 'ok');
            } catch (e) { toast(e.message, 'err'); }
        };
    });
    if (S.sqlitePath) openSqlite();
}
function refreshSqlite() { if (S.pkg && S.sqlitePath) openSqlite(S.sqlitePath); }

// ============== MANIFEST tab ==============
async function loadManifest() {
    if (!S.pkg) return;
    try {
        const d = await api.get(`/api/apps/${encodeURIComponent(S.pkg)}/manifest`);
        $('#manifest-summary').innerHTML = `
            <div class="kv"><div class="k">package</div><div class="v mono">${fmt.esc(d.packageName)}</div></div>
            <div class="kv"><div class="k">version</div><div class="v">${fmt.esc(d.versionName)} (${d.versionCode})</div></div>
            <div class="kv"><div class="k">min sdk</div><div class="v">${d.minSdk}</div></div>
            <div class="kv"><div class="k">target sdk</div><div class="v">${d.targetSdk}</div></div>
            <div class="kv"><div class="k">permissions</div><div class="v">${d.permissions.length}</div></div>
        `;
        $('#manifest-xml').textContent = d.xml || '(failed to decode)';
    } catch (e) { toast(e.message, 'err'); }
}
function initManifest() {
    once('manifest', () => { $('#manifest-refresh').onclick = loadManifest; });
    loadManifest();
}
function refreshManifest() { if (S.pkg) loadManifest(); }

// ============== COMPONENTS tab ==============
// Live runtime view of activities/services/receivers/providers via
// PackageManager. The static deep view (intent filters + ADB exploit
// commands) lives in APK Auditor; index.html surfaces a CTA strip
// pointing there.
//
// For apps with hundreds of components a name filter is essential.
// Keep the latest payload in S.componentsData so the filter can
// re-render without re-fetching.
async function loadComponents() {
    if (!S.pkg) return;
    try {
        const d = await api.get(`/api/apps/${encodeURIComponent(S.pkg)}/components`);
        S.componentsData = d;
        renderComponentsFiltered();
    } catch (e) { toast(e.message, 'err'); }
}
function renderComponentsFiltered() {
    const d = S.componentsData;
    if (!d) return;
    const q = ($('#components-filter')?.value || '').trim().toLowerCase();
    const exportedOnly = $('#components-exported-only')?.getAttribute('aria-pressed') === 'true';
    // Filter by both name and (optionally) exported flag.
    const passes = (c) => (!q || c.name.toLowerCase().includes(q)) && (!exportedOnly || c.exported);
    // Sort exported components to the top of each group so the user can see
    // the attack surface at a glance instead of scrolling past 100 private
    // activities to find the 3 exported ones.
    const sortExportedFirst = (arr) => arr.slice().sort((a, b) => {
        if (a.exported !== b.exported) return a.exported ? -1 : 1;
        return a.name.localeCompare(b.name);
    });
    const groups = [
        ['Activities', sortExportedFirst((d.activities || []).filter(passes))],
        ['Services',   sortExportedFirst((d.services   || []).filter(passes))],
        ['Receivers',  sortExportedFirst((d.receivers  || []).filter(passes))],
        ['Providers',  sortExportedFirst((d.providers  || []).filter(passes))],
    ];
    const totalShown = groups.reduce((n, g) => n + g[1].length, 0);
    const totalAll = (d.activities||[]).length + (d.services||[]).length + (d.receivers||[]).length + (d.providers||[]).length;
    const totalExported = [d.activities, d.services, d.receivers, d.providers]
        .reduce((n, list) => n + (list || []).filter(c => c.exported).length, 0);
    const countEl = $('#components-count');
    if (countEl) {
        const filtered = q || exportedOnly;
        countEl.textContent = filtered ? `${totalShown} / ${totalAll} match` : `${totalAll} total · ${totalExported} exported`;
    }
    $('#components-list').innerHTML = groups.map(([title, items]) => {
        // Hide entire group when the active filters empty it.
        if ((q || exportedOnly) && items.length === 0) return '';
        return `
            <div class="component-group">
                <h3>${title} <span class="count">${items.length}</span></h3>
                ${items.map(c => `
                    <div class="component-row ${c.exported ? 'exported' : ''}">
                        <div class="component-name">${fmt.esc(c.name)}${c.exported ? '<span class="tg danger">exported</span>' : ''}</div>
                        ${c.intentFilters && c.intentFilters.length ? `<div class="component-filters">${c.intentFilters.map(f => fmt.esc(f)).join('<br>')}</div>` : ''}
                    </div>
                `).join('') || '<div class="empty small">no matches</div>'}
            </div>`;
    }).join('') || `<div class="empty">No components match the current filters.</div>`;
}
function initComponents() {
    once('components', () => {
        $('#components-refresh').onclick = loadComponents;
        // Debounced so typing in a 100+ component list stays smooth.
        $('#components-filter')?.addEventListener('input', debounce(renderComponentsFiltered, 120));
        // "Exported only" toggle: flip aria-pressed and re-render.
        const tog = $('#components-exported-only');
        if (tog) tog.onclick = () => {
            const pressed = tog.getAttribute('aria-pressed') === 'true';
            tog.setAttribute('aria-pressed', String(!pressed));
            renderComponentsFiltered();
        };
    });
    loadComponents();
}
function refreshComponents() { if (S.pkg) loadComponents(); }

// ============== NATIVE tab ==============
async function loadNative() {
    if (!S.pkg) return;
    try {
        const d = await api.get(`/api/apps/${encodeURIComponent(S.pkg)}/native`);
        $('#native-list').innerHTML = d.libs.map(l => `
            <div class="native-card">
                <div class="name">${fmt.esc(l.name)}</div>
                <div class="path">${fmt.esc(l.path)}</div>
                <div class="tags">
                    <span class="tg accent">${fmt.bytes(l.size)}</span>
                    <span class="tg">${fmt.esc(l.arch || '?')}</span>
                    ${l.stripped ? '<span class="tg warn">stripped</span>' : '<span class="tg cyan">symbols</span>'}
                </div>
                <div class="actions">
                    <button class="btn ghost small" data-so-path="${fmt.esc(l.path)}" data-so-name="${fmt.esc(l.name)}" title="Download">
                        <svg class="ic ic-sm"><use href="#i-download"/></svg> Download
                    </button>
                </div>
            </div>
        `).join('') || '<div class="empty">No native libraries.</div>';
    } catch (e) { toast(e.message, 'err'); }
}
function downloadSo(path, name) {
    if (!S.pkg) return;
    // Use a transient <a download> so the cookie ships with the request and
    const url = `/api/apps/${encodeURIComponent(S.pkg)}/native/raw?path=${encodeURIComponent(path)}`;
    downloadBlob(url, name);
}
function initNative() {
    once('native', () => {
        $('#native-refresh').onclick = loadNative;
        $('#native-list').addEventListener('click', e => {
            const b = e.target.closest('[data-so-path]');
            if (b) downloadSo(b.dataset.soPath, b.dataset.soName);
        });
    });
    loadNative();
}
function refreshNative() { if (S.pkg) loadNative(); }

// ============== PROCESSES tab ==============
async function loadProcesses() {
    const f = $('#proc-filter').value.trim().toLowerCase();
    try {
        const d = await api.get('/api/live/processes' + (f ? `?pkg=${encodeURIComponent(f)}` : ''));
        const procs = d.processes || [];
        $('#proc-count').textContent = `${procs.length} proc${procs.length === 1 ? '' : 's'}`;
        const rows = procs.map(p => `<tr data-pid="${p.pid}" data-name="${fmt.esc(p.name)}">
            <td class="num">${p.pid}</td>
            <td>${(p.packages || []).map(fmt.esc).join('<br>') || `<span class="null mono">system uid ${p.uid}</span>`}</td>
            <td>${fmt.esc(p.name)}</td>
            <td>${fmt.esc(p.cmdline)}</td>
            <td>${p.state}</td>
            <td class="num">${p.threads}</td>
            <td class="num">${fmt.bytes(p.rssKb * 1024)}</td>
            <td><button class="btn ghost small" data-action="logcat" title="View logcat for this PID">📜 logs</button></td>
        </tr>`).join('');
        $('#proc-table').innerHTML = `<table><thead><tr><th>PID</th><th>Package</th><th>Name</th><th>Cmdline</th><th>State</th><th>Thr</th><th>RSS</th><th></th></tr></thead><tbody>${rows}</tbody></table>`;
    } catch (e) { toast(e.message, 'err'); }
}
function initProcesses() {
    once('processes', () => {
        $('#proc-refresh').onclick = loadProcesses;
        $('#proc-filter').addEventListener('input', debounce(loadProcesses, 300));

        // Click on a "📜 logs" button → jump to Logcat tab with --pid=<this row's pid>.
        // Also right-click anywhere on a row gives the same affordance.
        const handler = e => {
            const btn = e.target.closest('[data-action="logcat"]');
            const row = e.target.closest('tr[data-pid]');
            if (!btn && e.type !== 'contextmenu') return;
            if (!row) return;
            e.preventDefault();
            const pid = row.dataset.pid;
            S.pendingLogcatPid = pid;
            toast(`Following PID ${pid} (${row.dataset.name}) in Logcat`, 'ok');
            showTab('logcat');
        };
        $('#proc-table').addEventListener('click', handler);
        $('#proc-table').addEventListener('contextmenu', handler);
    });
    loadProcesses();
}
function refreshProcesses() { loadProcesses(); }

// ============== NETWORK tab ==============
async function loadNet() {
    const f = $('#net-filter').value.trim().toLowerCase();
    try {
        const d = await api.get('/api/live/connections');
        const conns = (d.connections || []).filter(c =>
            !f || c.localAddr.includes(f) || c.remoteAddr.includes(f) ||
            c.state.toLowerCase().includes(f) || String(c.uid).includes(f) ||
            (c.packages || []).some(p => p.toLowerCase().includes(f))
        );
        $('#net-count').textContent = `${conns.length} sock${conns.length === 1 ? '' : 's'}`;
        const rows = conns.map(c => `<tr>
            <td>${c.proto}</td>
            <td>${fmt.esc(c.localAddr)}</td>
            <td>${fmt.esc(c.remoteAddr)}</td>
            <td>${c.state}</td>
            <td>${(c.packages || []).map(fmt.esc).join('<br>') || `<span class="null mono">system uid ${c.uid}</span>`}</td>
        </tr>`).join('');
        $('#net-table').innerHTML = `<table><thead><tr><th>Proto</th><th>Local</th><th>Remote</th><th>State</th><th>Package</th></tr></thead><tbody>${rows}</tbody></table>`;
    } catch (e) { toast(e.message, 'err'); }
}
function initNet() {
    once('net', () => {
        $('#net-refresh').onclick = loadNet;
        $('#net-filter').addEventListener('input', debounce(loadNet, 300));
    });
    loadNet();
}
function refreshNet() { loadNet(); }

// ============== LOGCAT tab ==============
// Polling-based. The daemon keeps a ring buffer fed by `log stream`;
// fetch incremental chunks every ~1s using a `from` cursor.
let lcTimer = null;
let lcCursor = 0;
let lcSearchRegex = null;
async function lcPoll() {
    const filter = ($('#lc-filter').value || '').trim();
    const pid = parseInt($('#lc-pid').value, 10) || 0;
    const params = new URLSearchParams({ from: lcCursor, limit: 500 });
    if (filter && filter !== '*:V') params.set('filter', filter);
    if (pid > 0) params.set('pid', pid);
    try {
        const r = await api.get('/api/live/logcat?' + params.toString());
        lcCursor = r.nextFrom || lcCursor;
        (r.lines || []).forEach(entry => appendLogcatLine(entry.line));
        $('#lc-status').textContent = pid > 0 ? `live · pid ${pid} · ${r.buffered} buffered`
                                              : `live · ${r.buffered} buffered`;
    } catch (e) {
        $('#lc-status').textContent = `error: ${e.message}`;
    }
}
function lcStart() {
    lcStop();
    lcCursor = 0; // re-fetch from where the buffer starts
    $('#lc-out').innerHTML = '';
    $('#lc-status').textContent = 'starting...';
    lcPoll();
    lcTimer = setInterval(lcPoll, 1000);
}
function appendLogcatLine(line) {
    const out = $('#lc-out');
    const sev = (line.match(/\s([VDIWEF])\s/) || [])[1] || 'V';
    const onlyMatching = $('#lc-only-matching')?.checked;
    if (lcSearchRegex) {
        if (!lcSearchRegex.test(line)) { if (onlyMatching) return; }
    }
    const span = document.createElement('span');
    span.className = sev;
    if (lcSearchRegex) {
        // Highlight all matches in the line.
        const html = fmt.esc(line).replace(lcSearchRegex, m => `<mark>${m}</mark>`);
        span.innerHTML = html + '\n';
    } else {
        span.textContent = line + '\n';
    }
    out.appendChild(span);
    if ($('#lc-autoscroll').checked) out.scrollTop = out.scrollHeight;
    while (out.childNodes.length > 5000) out.removeChild(out.firstChild);
    // Update search count
    if (lcSearchRegex) {
        const total = out.querySelectorAll('mark').length;
        $('#lc-search-count').textContent = `${total} match${total === 1 ? '' : 'es'}`;
    } else {
        $('#lc-search-count').textContent = '';
    }
}
function lcStop() {
    if (lcTimer) { clearInterval(lcTimer); lcTimer = null; }
    $('#lc-status').textContent = 'stopped';
}
function lcSave() {
    const text = $('#lc-out').textContent;
    if (!text.trim()) { toast('Console buffer is empty', 'err'); return; }
    const blob = new Blob([text], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    a.download = `logcat-${stamp}.txt`;
    document.body.appendChild(a); a.click(); a.remove();
    toast(`Saved ${a.download}`, 'ok');
}
function lcApplySearch() {
    const raw = $('#lc-search').value.trim();
    if (!raw) {
        lcSearchRegex = null;
        $('#lc-search-count').textContent = '';
        // Strip any existing <mark>s by re-rendering current text:
        const out = $('#lc-out');
        const lines = out.textContent.split('\n').filter(l => l.length);
        out.innerHTML = '';
        lines.forEach(l => appendLogcatLine(l));
        return;
    }
    try {
        lcSearchRegex = new RegExp(raw, 'gi');
        // Re-render existing lines with the new regex.
        const out = $('#lc-out');
        const lines = out.textContent.split('\n').filter(l => l.length);
        out.innerHTML = '';
        $('#lc-search-count').textContent = '';
        lines.forEach(l => appendLogcatLine(l));
    } catch (e) {
        toast(`Invalid regex: ${e.message}`, 'err');
    }
}
function initLogcat() {
    once('logcat', () => {
        $('#lc-start').onclick = lcStart;
        $('#lc-stop').onclick = lcStop;
        $('#lc-clear').onclick = () => { $('#lc-out').innerHTML = ''; $('#lc-search-count').textContent = ''; };
        $('#lc-save').onclick = lcSave;
        $('#lc-search').addEventListener('input', debounce(lcApplySearch, 250));
        $('#lc-only-matching').addEventListener('change', lcApplySearch);
    });
    // Auto-start when the tab is opened. Hunt-for-the-start-button on
    // a "live console" tab is bad UX. The user can hit Stop to pause,
    // or change pid / filter and click Start to reset.
    if (S.pendingLogcatPid) {
        $('#lc-pid').value = S.pendingLogcatPid;
        S.pendingLogcatPid = null;
    }
    if (!lcTimer) lcStart();
}
function refreshLogcat() {
    if (S.pendingLogcatPid) {
        lcStop();
        $('#lc-pid').value = S.pendingLogcatPid;
        S.pendingLogcatPid = null;
        lcStart();
    }
}

// ============== SHELL tab ==============
async function shRun() {
    const cmd = $('#sh-cmd').value.trim(); if (!cmd) return;
    const out = $('#sh-out');
    out.textContent += `\n$ ${cmd}\n`;
    $('#sh-cmd').value = '';
    try {
        const r = await api.post('/api/live/exec', { command: cmd });
        if (r.stdout) out.textContent += r.stdout + '\n';
        if (r.stderr) out.textContent += `[stderr] ${r.stderr}\n`;
        out.textContent += `[exit ${r.code}]\n`;
    } catch (e) { out.textContent += `[error] ${e.message}\n`; }
    out.scrollTop = out.scrollHeight;
}
function initShell() {
    once('shell', () => {
        $('#sh-run').onclick = shRun;
        $('#sh-clear').onclick = () => { $('#sh-out').textContent = ''; };
        $('#sh-cmd').addEventListener('keydown', e => { if (e.key === 'Enter') shRun(); });
    });
}
function refreshShell() {}

// ============== Dispatch ==============
const INITS = { files: initFiles, prefs: initPrefs, sqlite: initSqlite, native: initNative, processes: initProcesses, net: initNet, logcat: initLogcat, shell: initShell };
const REFRESH = { files: refreshFiles, prefs: refreshPrefs, sqlite: refreshSqlite, native: refreshNative, processes: refreshProcesses, net: refreshNet, logcat: refreshLogcat, shell: refreshShell };
function initTab(name) { (INITS[name] || (() => {}))(); }
function refreshTab(name) { (REFRESH[name] || (() => {}))(); }

function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

// ============== Boot ==============
loadApps();
showTab('welcome');

})();
