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
})();
