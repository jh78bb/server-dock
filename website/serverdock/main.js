// Keep navigation usable without JavaScript; enhance the current section when available.
const links = [...document.querySelectorAll('.nav-links a[href^="#"]')];
if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      for (const link of links) {
        if (link.hash === `#${entry.target.id}`) link.setAttribute('aria-current', 'location');
        else link.removeAttribute('aria-current');
      }
    }
  }, { rootMargin: '-15% 0px -55% 0px' });
  document.querySelectorAll('main > section[id]').forEach(section => observer.observe(section));
}

// Keep ordinary image links as the fallback; a native dialog adds an in-page preview.
if (typeof HTMLDialogElement !== 'undefined') {
  const dialog = document.createElement('dialog');
  dialog.className = 'screen-dialog';
  dialog.setAttribute('aria-labelledby', 'screen-dialog-title');
  const bar = document.createElement('div');
  bar.className = 'screen-dialog-bar';
  const title = document.createElement('p');
  title.id = 'screen-dialog-title';
  const close = document.createElement('button');
  close.className = 'screen-dialog-close';
  close.type = 'button';
  close.textContent = document.documentElement.lang === 'ko' ? '닫기 ×' : 'Close ×';
  const preview = document.createElement('img');
  const imageFrame = document.createElement('div');
  imageFrame.className = 'screen-dialog-image';
  const controls = document.createElement('img');
  controls.src = 'img/window-controls.svg';
  controls.className = 'window-controls';
  controls.alt = '';
  controls.setAttribute('aria-hidden', 'true');
  imageFrame.append(preview, controls);
  const original = document.createElement('a');
  original.className = 'screen-dialog-original';
  original.target = '_blank';
  original.rel = 'noopener';
  original.textContent = document.documentElement.lang === 'ko' ? '원본 이미지 열기 ↗' : 'Open original image ↗';
  bar.append(title, close);
  dialog.append(bar, imageFrame, original);
  document.body.append(dialog);
  let opener;
  close.addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => {
    const box = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom)) dialog.close();
  });
  dialog.addEventListener('close', () => opener?.focus());
  document.querySelectorAll('[data-screen]').forEach(link => {
    link.addEventListener('click', event => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      opener = link;
      preview.src = link.href;
      preview.alt = link.querySelector('img').alt;
      controls.hidden = !link.querySelector('[data-window-controls]');
      title.textContent = preview.alt;
      original.href = link.href;
      dialog.showModal();
      close.focus();
    });
  });
}
