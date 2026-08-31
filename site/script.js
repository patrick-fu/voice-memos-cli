(() => {
  const toggle = document.querySelector('.language');
  const localized = document.querySelectorAll('[data-zh][data-en]');
  const localizedAria = document.querySelectorAll('[data-aria-zh][data-aria-en]');
  const setLanguage = (language) => {
    document.documentElement.lang = language === 'en' ? 'en' : 'zh-CN';
    localized.forEach((element) => { element.textContent = element.dataset[language]; });
    localizedAria.forEach((element) => { element.setAttribute('aria-label', element.dataset[`aria${language[0].toUpperCase()}${language.slice(1)}`]); });
    toggle.textContent = language === 'en' ? '中文' : 'EN';
    toggle.setAttribute('aria-pressed', String(language === 'en'));
    localStorage.setItem('vmemo-language', language);
  };
  const saved = localStorage.getItem('vmemo-language');
  if (saved === 'en' || saved === 'zh') setLanguage(saved);
  toggle.addEventListener('click', () => setLanguage(document.documentElement.lang === 'en' ? 'zh' : 'en'));

  const copiedLabel = (button) => {
    const language = document.documentElement.lang === 'en' ? 'en' : 'zh';
    return button.dataset[`copied${language[0].toUpperCase()}${language.slice(1)}`];
  };
  document.querySelectorAll('[data-copy-target]').forEach((button) => {
    button.addEventListener('click', async () => {
      const source = document.getElementById(button.dataset.copyTarget);
      if (!source) return;
      try {
        await navigator.clipboard.writeText(source.textContent.trim());
      } catch {
        const range = document.createRange();
        range.selectNodeContents(source);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        document.execCommand('copy');
        selection.removeAllRanges();
      }
      button.textContent = copiedLabel(button);
      window.setTimeout(() => { button.textContent = button.dataset[document.documentElement.lang === 'en' ? 'en' : 'zh']; }, 1600);
    });
  });
})();
