(() => {
  const root = document.documentElement;
  const themeKey = "vmemo-theme";
  const langKey = "vmemo-lang";
  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  const status = document.getElementById("copy-status");
  const themeBtn = document.querySelector("[data-theme-toggle]");
  const langBtn = document.querySelector("[data-lang-toggle]");
  const termCommand = document.getElementById("term-command");
  const termOutput = document.getElementById("term-output");
  const copyCommandBtn = document.querySelector("[data-copy-command]");
  const copyOutputBtn = document.querySelector("[data-copy-output]");
  const tabButtons = [...document.querySelectorAll("[data-term-tab]")];
  const viewButtons = [...document.querySelectorAll("[data-term-view]")];

  const recA = "7F3A91C2-0B14-4E8D-9C55-A2D80F1B6E44";
  const recB = "12D90E6B-88C1-4A27-B3F0-6C4E19A8D731";
  const recC = "9AA4C018-5F62-4D11-8E77-01B3C9D24650";
  const dest = "/Users/you/Downloads/standup.m4a";

  let theme = "light";
  let lang = "zh";
  let tab = "list";
  let view = "human";
  let statusTimer = 0;
  let lastOutputText = "";

  const copyLabel = {
    zh: { ok: "已复制", fail: "复制失败" },
    en: { ok: "Copied", fail: "Copy failed" },
  };

  const meta = {
    zh: {
      title: "vmemo · 面向 agent 的 Voice Memos CLI",
      description:
        "安全只读的 macOS CLI：列出、搜索、检查并导出 Apple Voice Memos 的 .m4a 副本。Apple 公证，universal2，免 Root。",
    },
    en: {
      title: "vmemo · Agent-friendly Voice Memos CLI",
      description:
        "A safe, read-only macOS CLI to list, search, inspect, and export .m4a copies of Apple Voice Memos. Apple notarized, universal2, zero root.",
    },
  };

  const demos = {
    list: {
      humanCmd: "vmemo list",
      jsonCmd: "vmemo list --json",
      human() {
        return table(
          ["ID", "Title"],
          [
            [recA, "Weekly standup"],
            [recB, "Product review"],
            [recC, "Interview notes"],
          ],
        );
      },
      json: {
        version: 1,
        status: "ok",
        data: {
          recordings: [
            { id: recA, title: "Weekly standup" },
            { id: recB, title: "Product review" },
            { id: recC, title: "Interview notes" },
          ],
        },
      },
      plain() {
        return `${recA}\tWeekly standup\n${recB}\tProduct review\n${recC}\tInterview notes`;
      },
    },
    search: {
      humanCmd: 'vmemo search --query "standup"',
      jsonCmd: 'vmemo search --query "standup" --json',
      human() {
        return table(["ID", "Title"], [[recA, "Weekly standup"]]);
      },
      json: {
        version: 1,
        status: "ok",
        data: { recordings: [{ id: recA, title: "Weekly standup" }] },
      },
      plain() {
        return `${recA}\tWeekly standup`;
      },
    },
    export: {
      humanCmd: `vmemo export --id "${recA}" --output-path "$HOME/Downloads/standup.m4a"`,
      jsonCmd: `vmemo export --id "${recA}" --output-path "$HOME/Downloads/standup.m4a" --json`,
      human() {
        return `<p>Exported ${esc(recA)} to ${esc(dest)}.</p>`;
      },
      json: {
        version: 1,
        status: "ok",
        data: { id: recA, destination: dest },
      },
      plain() {
        return `Exported ${recA} to ${dest}.`;
      },
    },
    doctor: {
      humanCmd: "vmemo doctor",
      jsonCmd: "vmemo doctor --json",
      human() {
        return (
          `<p>Doctor: <span class="ok">ready</span></p>` +
          table(
            ["Check", "Status", "Code", "Details"],
            [
              ["runtime", "ready", "runtime_supported", "macOS 26"],
              ["voice_memos", "ready", "app_available", "Voice Memos build 1380"],
              ["library", "ready", "library_accessible", "group container"],
              ["schema", "ready", "schema_recognized", "VoiceMemos14"],
              ["signing", "ready", "signing_metadata_available", "Team ID 9N7UKH59LC"],
            ],
          )
        );
      },
      json: {
        version: 1,
        status: "ok",
        data: {
          status: "ready",
          checks: [
            { id: "runtime", status: "ready", code: "runtime_supported", details: ["macOS 26"] },
            { id: "voice_memos", status: "ready", code: "app_available", details: ["Voice Memos build 1380"] },
            { id: "library", status: "ready", code: "library_accessible", details: ["group container"] },
            { id: "schema", status: "ready", code: "schema_recognized", details: ["VoiceMemos14"] },
            { id: "signing", status: "ready", code: "signing_metadata_available", details: ["Team ID 9N7UKH59LC"] },
          ],
        },
      },
      plain() {
        return [
          "Doctor: ready",
          "runtime\tready\truntime_supported\tmacOS 26",
          "voice_memos\tready\tapp_available\tVoice Memos build 1380",
          "library\tready\tlibrary_accessible\tgroup container",
          "schema\tready\tschema_recognized\tVoiceMemos14",
          "signing\tready\tsigning_metadata_available\tTeam ID 9N7UKH59LC",
        ].join("\n");
      },
    },
  };

  function get(key) {
    try {
      return localStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  function set(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (_) {}
  }

  function esc(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");
  }

  function table(headers, rows) {
    const head = headers.map((h) => `<th>${esc(h)}</th>`).join("");
    const body = rows
      .map(
        (row) =>
          `<tr>${row.map((cell, i) => `<td>${i === 1 && row[1] === "ready" ? `<span class="ok">${esc(cell)}</span>` : esc(cell)}</td>`).join("")}</tr>`,
      )
      .join("");
    return `<table class="term-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
  }

  function highlightJson(value) {
    const json = JSON.stringify(value, null, 2);
    return json.replace(
      /("(?:\\.|[^"\\])*")\s*:|"((?:\\.|[^"\\])*)"|(-?\d+(?:\.\d+)?)|\b(true|false|null)\b/g,
      (match, key, str, num, lit) => {
        if (key) return `<span class="json-key">${esc(key)}</span>:`;
        if (str !== undefined) return `<span class="json-str">"${esc(str)}"</span>`;
        if (num) return `<span class="json-num">${esc(num)}</span>`;
        return esc(lit);
      },
    );
  }

  function resolvedTheme(next) {
    if (next === "light" || next === "dark") return next;
    return mq.matches ? "dark" : "light";
  }

  function applyTheme(next) {
    theme = resolvedTheme(next);
    root.dataset.theme = theme;
    const dark = theme === "dark";
    document.querySelector('meta[name="theme-color"]').content = dark ? "#000000" : "#f5f5f7";
    if (themeBtn) {
      themeBtn.setAttribute(
        "aria-label",
        lang === "zh" ? (dark ? "切换到浅色" : "切换到深色") : dark ? "Switch to light" : "Switch to dark",
      );
    }
  }

  function applyLang(next) {
    lang = next === "en" ? "en" : "zh";
    root.dataset.lang = lang;
    root.lang = lang === "zh" ? "zh-CN" : "en";
    const pack = meta[lang];
    document.title = pack.title;
    document.querySelector('meta[name="description"]').content = pack.description;
    document.querySelector('meta[property="og:title"]').content = pack.title;
    document.querySelector('meta[property="og:description"]').content = pack.description;
    document.querySelector('meta[name="twitter:title"]').content = pack.title;
    document.querySelector('meta[name="twitter:description"]').content = pack.description;
    if (langBtn) {
      langBtn.setAttribute("aria-label", lang === "zh" ? "Switch to English" : "切换到中文");
    }
    document.querySelectorAll("[data-aria-zh][data-aria-en]").forEach((el) => {
      el.setAttribute("aria-label", lang === "zh" ? el.dataset.ariaZh : el.dataset.ariaEn);
    });
    applyTheme(theme);
  }

  function currentDemo() {
    return demos[tab];
  }

  function renderTerm() {
    const demo = currentDemo();
    const command = view === "json" ? demo.jsonCmd : demo.humanCmd;
    termCommand.textContent = command;
    if (view === "json") {
      termOutput.innerHTML = `<pre>${highlightJson(demo.json)}</pre>`;
      lastOutputText = JSON.stringify(demo.json, null, 2);
    } else {
      termOutput.innerHTML = demo.human();
      lastOutputText = demo.plain();
    }
    tabButtons.forEach((btn) => {
      const on = btn.dataset.termTab === tab;
      btn.setAttribute("aria-selected", String(on));
      btn.tabIndex = on ? 0 : -1;
    });
    termOutput.setAttribute("aria-labelledby", `tab-${tab}`);
    viewButtons.forEach((btn) => {
      btn.setAttribute("aria-pressed", String(btn.dataset.termView === view));
    });
  }

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }
    const area = document.createElement("textarea");
    area.value = text;
    area.readOnly = true;
    area.style.cssText = "position:fixed;left:-9999px;top:0;opacity:0";
    document.body.append(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    if (!ok) throw new Error("copy failed");
  }

  function flash(btn, ok) {
    const pack = copyLabel[lang];
    const message = ok ? pack.ok : pack.fail;
    clearTimeout(statusTimer);
    status.textContent = message;
    statusTimer = window.setTimeout(() => {
      status.textContent = "";
    }, 2200);
    if (!btn) return;
    btn.classList.toggle("is-copied", ok);
    const copied = btn.querySelector("[data-icon-copied]");
    const idle = btn.querySelector("[data-icon-copy]");
    if (copied && idle) {
      if (btn._iconTimer) {
        clearTimeout(btn._iconTimer);
        btn._iconTimer = 0;
      }
      idle.hidden = ok;
      copied.hidden = !ok;
      btn._iconTimer = window.setTimeout(() => {
        idle.hidden = false;
        copied.hidden = true;
        btn.classList.remove("is-copied");
        btn._iconTimer = 0;
      }, 1600);
    }
  }

  async function onCopy(btn, text) {
    try {
      await copyText(text);
      flash(btn, true);
    } catch (_) {
      flash(btn, false);
    }
  }

  const storedTheme = get(themeKey);
  const storedLang = get(langKey);
  applyLang(storedLang || ((navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en"));
  applyTheme(storedTheme === "light" || storedTheme === "dark" ? storedTheme : resolvedTheme("system"));
  renderTerm();

  themeBtn?.addEventListener("click", () => {
    const next = theme === "dark" ? "light" : "dark";
    applyTheme(next);
    set(themeKey, next);
  });

  mq.addEventListener("change", () => {
    if (get(themeKey) !== "light" && get(themeKey) !== "dark") applyTheme("system");
  });

  langBtn?.addEventListener("click", () => {
    const next = lang === "zh" ? "en" : "zh";
    applyLang(next);
    set(langKey, next);
  });

  tabButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      tab = btn.dataset.termTab;
      renderTerm();
    });
  });

  document.querySelector("[data-term-tabs]")?.addEventListener("keydown", (event) => {
    const keys = { ArrowRight: 1, ArrowLeft: -1 };
    const delta = keys[event.key];
    if (!delta) return;
    event.preventDefault();
    const index = tabButtons.findIndex((btn) => btn.dataset.termTab === tab);
    const next = tabButtons[(index + delta + tabButtons.length) % tabButtons.length];
    tab = next.dataset.termTab;
    next.focus();
    renderTerm();
  });

  viewButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      view = btn.dataset.termView;
      renderTerm();
    });
  });

  copyCommandBtn?.addEventListener("click", () => onCopy(copyCommandBtn, termCommand.textContent.trim()));
  copyOutputBtn?.addEventListener("click", () => onCopy(copyOutputBtn, lastOutputText));

  document.querySelectorAll("[data-copy-target]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const target = document.getElementById(btn.dataset.copyTarget);
      onCopy(btn, (target?.textContent || "").trim());
    });
  });
})();
