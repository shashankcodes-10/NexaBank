(function () {
    const KEY = 'nexabank-theme';
    const root = document.documentElement;

    function preferredTheme() {
        let saved = null;
        try { saved = localStorage.getItem(KEY); } catch (e) {}
        if (saved === 'light' || saved === 'dark') return saved;
        return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }

    function applyTheme(theme) {
        root.setAttribute('data-theme', theme);
        try { localStorage.setItem(KEY, theme); } catch (e) {}
        const icon = document.getElementById('themeIcon');
        if (icon) icon.className = theme === 'dark' ? 'bi bi-sun-fill' : 'bi bi-moon-stars-fill';
    }

    applyTheme(preferredTheme());
    document.addEventListener('DOMContentLoaded', function () {
        applyTheme(preferredTheme());
        const toggle = document.getElementById('themeToggle');
        if (toggle) toggle.addEventListener('click', function () {
            applyTheme(root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
        });
    });
})();
