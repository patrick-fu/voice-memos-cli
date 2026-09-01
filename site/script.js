(() => {
  const r = document.documentElement,
    ts = "vmemo-theme",
    ls = "vmemo-language",
    mq = matchMedia("(prefers-color-scheme: dark)"),
    copy = document.querySelectorAll(".copy-button"),
    status = document.getElementById("copy-status");
  let lang = "zh";
  let statusTimer;
  const get = (k) => {
      try {
        return localStorage.getItem(k);
      } catch (_) {
        return null;
      }
    },
    set = (k, v) => {
      try {
        localStorage.setItem(k, v);
      } catch (_) {}
    };
  function themeColor() {
    document.querySelector('meta[name="theme-color"]').content =
      r.dataset.theme === "dark" || r.dataset.theme === "system" && mq.matches
        ? "#20251f"
        : "#fbfaf6";
  }
  function applyTheme(t) {
    r.dataset.theme = ["system", "light", "dark"].includes(t) ? t : "system";
    document.querySelectorAll("[data-theme-choice]").forEach((b) =>
      b.setAttribute(
        "aria-pressed",
        String(b.dataset.themeChoice === r.dataset.theme),
      )
    );
    themeColor();
  }
  function key(prefix) {
    return `${prefix}${lang[0].toUpperCase()}${lang.slice(1)}`;
  }
  function translate() {
    document.querySelectorAll("[data-zh][data-en]").forEach((e) =>
      e.textContent = e.dataset[lang]
    );
    document.querySelectorAll("[data-aria-zh][data-aria-en]").forEach((e) =>
      e.setAttribute("aria-label", e.dataset[key("aria")])
    );
    r.lang = lang === "zh" ? "zh-CN" : "en";
    document.title = lang === "zh"
      ? "vmemo · 找录音，导出副本"
      : "vmemo · Find and copy your Voice Memos";
    const d = lang === "zh"
      ? "vmemo 在终端里按标题搜索 Voice Memos，并导出 .m4a 副本。原文件保持不动。"
      : "vmemo searches Voice Memos by title in Terminal and exports .m4a copies. The originals stay untouched.";
    document.querySelector('meta[name="description"]').content = d;
    document.querySelector('meta[property="og:title"]').content =
      document.title;
    document.querySelector('meta[property="og:description"]').content = d;
    const imageAlt = lang === "zh"
      ? "vmemo：找录音，导出副本，原文件保持不动"
      : "vmemo: Find a recording, save a copy, leave the original untouched.";
    document.querySelector('meta[property="og:image:alt"]').content = imageAlt;
    document.querySelector('meta[name="twitter:title"]').content =
      document.title;
    document.querySelector('meta[name="twitter:description"]').content = d;
    document.querySelector('meta[name="twitter:image:alt"]').content = imageAlt;
    document.querySelector(".language").textContent = lang === "zh"
      ? "EN"
      : "中文";
  }
  function message(b, ok) {
    const m = ok ? b.dataset[key("copied")] : b.dataset[key("failed")];
    clearTimeout(statusTimer);
    status.textContent = m;
    statusTimer = setTimeout(() => status.textContent = "", 2400);
  }
  async function copyText(t) {
    if (navigator.clipboard && isSecureContext) {
      await navigator.clipboard.writeText(t);
      return;
    }
    const a = document.createElement("textarea");
    a.value = t;
    a.readOnly = true;
    a.style.cssText = "position:fixed;opacity:0";
    document.body.append(a);
    a.select();
    const ok = document.execCommand("copy");
    a.remove();
    if (!ok) throw Error("copy failed");
  }
  applyTheme(get(ts) || r.dataset.theme || "system");
  lang = get(ls) === "en" ? "en" : "zh";
  translate();
  document.querySelectorAll("[data-theme-choice]").forEach((b) =>
    b.addEventListener("click", () => {
      applyTheme(b.dataset.themeChoice);
      set(ts, r.dataset.theme);
    })
  );
  mq.addEventListener("change", () => {
    if (r.dataset.theme === "system") themeColor();
  });
  document.querySelector(".language").addEventListener("click", () => {
    lang = lang === "zh" ? "en" : "zh";
    set(ls, lang);
    translate();
  });
  copy.forEach((b) =>
    b.addEventListener("click", async () => {
      try {
        await copyText(
          document.getElementById(b.dataset.copyTarget).textContent.trim(),
        );
        message(b, true);
      } catch (_) {
        message(b, false);
      }
    })
  );
  const reveals = document.querySelectorAll(".reveal");
  if (
    matchMedia("(prefers-reduced-motion: reduce)").matches ||
    !("IntersectionObserver" in window)
  ) reveals.forEach((e) => e.classList.add("in-view"));
  else {
    const o = new IntersectionObserver((es) =>
      es.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add("in-view");
          o.unobserve(e.target);
        }
      }), { threshold: .12 });
    reveals.forEach((e) => o.observe(e));
  }
})();
