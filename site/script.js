(() => {
  const reduceMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  document.documentElement.classList.add("js");

  const storage = {
    get(key) {
      try { return localStorage.getItem(key); } catch { return null; }
    },
    set(key, value) {
      try { localStorage.setItem(key, value); } catch { /* ignore quota / private mode */ }
    }
  };

  const langKey = (language, prefix) => `${prefix}${language[0].toUpperCase()}${language.slice(1)}`;
  const currentLang = () => (document.documentElement.lang === "en" ? "en" : "zh");

  const toggle = document.querySelector(".language");
  const setLanguage = (language) => {
    const lang = language === "en" ? "en" : "zh";
    document.documentElement.lang = lang === "en" ? "en" : "zh-CN";
    document.querySelectorAll("[data-zh][data-en]").forEach((element) => {
      element.textContent = element.dataset[lang];
    });
    document.querySelectorAll("[data-aria-zh][data-aria-en]").forEach((element) => {
      element.setAttribute("aria-label", element.dataset[langKey(lang, "aria")]);
    });
    document.querySelectorAll(".copy").forEach((button) => {
      if (button.classList.contains("is-copied")) {
        const label = button.querySelector(".copy-label");
        if (label) label.textContent = button.dataset[langKey(lang, "copied")];
      } else if (button.classList.contains("is-failed")) {
        const label = button.querySelector(".copy-label");
        if (label) label.textContent = button.dataset[langKey(lang, "failed")];
      }
    });
    toggle.textContent = lang === "en" ? "中文" : "EN";
    toggle.setAttribute("aria-pressed", String(lang === "en"));
    storage.set("vmemo-language", lang);
  };
  const saved = storage.get("vmemo-language");
  if (saved === "en" || saved === "zh") setLanguage(saved);
  toggle.addEventListener("click", () => setLanguage(currentLang() === "en" ? "zh" : "en"));

  const copyLive = document.querySelector(".copy-live");
  const copyTimers = new WeakMap();
  const copyText = async (text) => {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.position = "fixed";
    field.style.left = "-9999px";
    document.body.appendChild(field);
    field.select();
    const ok = document.execCommand("copy");
    field.remove();
    if (!ok) throw new Error("copy failed");
  };
  const resetCopyButton = (button) => {
    button.classList.remove("is-copied", "is-failed");
    const label = button.querySelector(".copy-label");
    const lang = currentLang();
    if (label) label.textContent = label.dataset[lang];
  };
  document.querySelectorAll("[data-copy-target]").forEach((button) => {
    button.addEventListener("click", async () => {
      const source = document.getElementById(button.dataset.copyTarget);
      if (!source) return;
      const lang = currentLang();
      const label = button.querySelector(".copy-label");
      const previous = copyTimers.get(button);
      if (previous) window.clearTimeout(previous);
      try {
        await copyText(source.textContent.trim());
        button.classList.add("is-copied");
        button.classList.remove("is-failed");
        if (label) label.textContent = button.dataset[langKey(lang, "copied")];
        if (copyLive) {
          copyLive.classList.remove("is-fail");
          copyLive.textContent = lang === "en" ? "Copied the install command." : "已复制安装命令。";
        }
      } catch {
        button.classList.add("is-failed");
        button.classList.remove("is-copied");
        if (label) label.textContent = button.dataset[langKey(lang, "failed")];
        if (copyLive) {
          copyLive.classList.add("is-fail");
          copyLive.textContent = lang === "en"
            ? "Copy failed. Select the command and copy it manually."
            : "复制失败，请手动选择命令再复制。";
        }
      }
      copyTimers.set(button, window.setTimeout(() => {
        resetCopyButton(button);
        if (copyLive) copyLive.textContent = "";
      }, 1800));
    });
  });

  const demos = {
    doctor: {
      cmd: "vmemo doctor --json",
      exit: "exit 0",
      json: {
        version: 1,
        status: "ok",
        data: {
          status: "ready",
          checks: [
            { id: "runtime", status: "ready", code: "runtime_supported", details: [] },
            { id: "voice_memos", status: "ready", code: "app_available", details: [] },
            { id: "library", status: "ready", code: "library_accessible", details: [] },
            { id: "schema", status: "ready", code: "schema_recognized", details: [] },
            { id: "signing", status: "ready", code: "signing_metadata_available", details: [] }
          ]
        }
      }
    },
    list: {
      cmd: "vmemo list --json",
      exit: "exit 0",
      json: { version: 1, status: "ok", data: { recordings: [{ id: "<opaque-id>", title: "<title>" }] } }
    },
    search: {
      cmd: "vmemo search --query \"<title fragment>\" --json",
      exit: "exit 0",
      json: { version: 1, status: "ok", data: { recordings: [{ id: "<opaque-id>", title: "<title>" }] } }
    },
    show: {
      cmd: "vmemo show --id \"<opaque-id>\" --json",
      exit: "exit 0",
      json: { version: 1, status: "ok", data: { id: "<opaque-id>", title: "<title>" } }
    },
    export: {
      cmd: "vmemo export --id \"<opaque-id>\" --output-path \"$HOME/Downloads/recording.m4a\" --json",
      exit: "exit 0",
      json: { version: 1, status: "ok", data: { id: "<opaque-id>", destination: "<absolute-destination>" } }
    }
  };

  const escapeHtml = (value) => value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
  const highlightJson = (raw) => escapeHtml(raw)
    .replace(/&quot;(.*?)&quot;(?=\s*:)/g, '<span class="tok-key">&quot;$1&quot;</span>')
    .replace(/:\s*&quot;(.*?)&quot;/g, ': <span class="tok-str">&quot;$1&quot;</span>')
    .replace(/\b(-?\d+)\b/g, '<span class="tok-num">$1</span>');

  const output = document.getElementById("demo-output");
  const exitNode = document.getElementById("demo-exit");
  const panel = document.getElementById("demo-panel");
  const tabs = Array.from(document.querySelectorAll(".cmd[data-demo]"));
  let playTimer = 0;
  let typeTimer = 0;

  const stopPlay = () => {
    window.clearTimeout(playTimer);
    window.clearTimeout(typeTimer);
    playTimer = 0;
    typeTimer = 0;
  };

  const renderDemo = (name, { animate } = { animate: true }) => {
    const demo = demos[name];
    if (!demo || !output) return;
    const json = JSON.stringify(demo.json, null, 2);
    const highlighted = highlightJson(json);
    const cmdHtml = `<span class="prompt-line">$ <span class="cmd-text">${escapeHtml(demo.cmd)}</span></span>\n`;
    if (exitNode) exitNode.textContent = demo.exit;
    tabs.forEach((tab) => {
      const selected = tab.dataset.demo === name;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
    });
    if (panel) panel.setAttribute("aria-labelledby", `tab-${name}`);
    if (!animate || reduceMotion()) {
      output.innerHTML = `${cmdHtml}${highlighted}`;
      return;
    }
    output.innerHTML = `<span class="prompt-line">$ </span>`;
    const prompt = demo.cmd;
    let i = 0;
    const step = () => {
      i += 1;
      output.innerHTML = `<span class="prompt-line">$ <span class="cmd-text">${escapeHtml(prompt.slice(0, i))}</span></span>`;
      if (i < prompt.length) {
        typeTimer = window.setTimeout(step, 12);
      } else {
        output.innerHTML = `${cmdHtml}${highlighted}`;
      }
    };
    typeTimer = window.setTimeout(step, 12);
  };

  tabs.forEach((tab) => {
    tab.tabIndex = tab.dataset.demo === "doctor" ? 0 : -1;
    tab.addEventListener("click", () => {
      stopPlay();
      renderDemo(tab.dataset.demo);
    });
  });
  document.querySelector(".command-list").addEventListener("keydown", (event) => {
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const index = tabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true");
    let next = index;
    if (event.key === "ArrowDown") next = (index + 1) % tabs.length;
    if (event.key === "ArrowUp") next = (index - 1 + tabs.length) % tabs.length;
    if (event.key === "Home") next = 0;
    if (event.key === "End") next = tabs.length - 1;
    stopPlay();
    renderDemo(tabs[next].dataset.demo, { animate: false });
    tabs[next].focus();
  });

  const sequence = ["doctor", "search", "show", "export"];
  const playButton = document.querySelector(".play-seq");
  playButton.addEventListener("click", () => {
    stopPlay();
    let step = 0;
    const run = () => {
      renderDemo(sequence[step]);
      step += 1;
      if (step < sequence.length) {
        playTimer = window.setTimeout(run, reduceMotion() ? 0 : 1600);
      }
    };
    run();
  });
  renderDemo("doctor", { animate: false });

  const reveals = document.querySelectorAll(".reveal");
  const showAll = () => reveals.forEach((el) => el.classList.add("in-view"));
  if (reduceMotion() || !("IntersectionObserver" in window)) {
    showAll();
  } else {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("in-view");
        io.unobserve(entry.target);
      });
    }, { threshold: 0.18, rootMargin: "0px 0px -6% 0px" });
    reveals.forEach((el) => io.observe(el));
  }
})();
