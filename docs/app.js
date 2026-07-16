document.querySelectorAll('[data-copy]').forEach((button) => {
  button.addEventListener('click', async () => {
    const target = document.getElementById(button.dataset.copy);
    if (!target) return;
    const text = target.innerText.trim();
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
      button.classList.add('is-copied');
      window.setTimeout(() => {
        button.textContent = 'Copy';
        button.classList.remove('is-copied');
      }, 1600);
    } catch (_) {
      button.textContent = 'Could not copy';
    }
  });
});
