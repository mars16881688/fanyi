(() => {
  'use strict';
  const motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)');
  const header = document.getElementById('site-header');
  const updateHeader = () => header.classList.toggle('scrolled', window.scrollY > 24);
  window.addEventListener('scroll', updateHeader, { passive: true });
  updateHeader();

  if (!motionPreference.matches && 'IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.remove('pending');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.08 });
    document.documentElement.classList.add('motion-ready');
    document.querySelectorAll('.reveal').forEach(element => {
      element.classList.add('pending');
      observer.observe(element);
    });
  }

  const demo = document.getElementById('demo-window');
  const translation = document.getElementById('demo-translation');
  const reply = document.getElementById('demo-reply');
  const english = document.getElementById('demo-english');
  const fullText = [translation.textContent, reply.textContent, english.textContent];
  const steps = Array.from(document.querySelectorAll('[data-step]'));
  const copy = document.getElementById('demo-copy');
  const progress = document.getElementById('demo-progress');
  const toggle = document.getElementById('play-toggle');
  const glyph = document.getElementById('play-glyph');
  const playLabel = document.getElementById('play-label');
  const status = document.getElementById('demo-status');
  const labels = ['选中英文消息', '小圆按钮出现，展开翻译 / 改写', '中文译文流式生成', '输入中文回复，生成英文回复', '复制英文回复'];
  const duration = 30000;
  let elapsed = 0;
  let lastTime = null;
  let paused = false;
  let frame = null;
  let currentStage = -1;

  const type = (element, text, start, end, time) => {
    const fraction = Math.max(0, Math.min(1, (time - start) / (end - start)));
    element.textContent = text.slice(0, Math.floor(text.length * fraction));
  };

  const render = time => {
    const stage = time < 2600 ? 0 : time < 6100 ? 1 : time < 12500 ? 2 : time < 25400 ? 3 : 4;
    demo.dataset.stage = String(stage);
    demo.classList.toggle('expanded', time >= 4300);
    type(translation, fullText[0], 6400, 11200, time);
    type(reply, fullText[1], 13000, 16900, time);
    type(english, fullText[2], 18200, 24500, time);
    copy.textContent = stage === 4 ? '已复制' : '复制';
    progress.style.transform = `scaleX(${time / duration})`;
    if (currentStage !== stage) {
      currentStage = stage;
      steps.forEach((step, index) => {
        step.classList.toggle('active', index === stage);
        if (index === stage) step.setAttribute('aria-current', 'step');
        else step.removeAttribute('aria-current');
      });
      status.textContent = `示意演示 · ${labels[stage]}`;
    }
  };

  const tick = now => {
    if (lastTime !== null) elapsed = (elapsed + now - lastTime) % duration;
    lastTime = now;
    render(elapsed);
    frame = window.requestAnimationFrame(tick);
  };
  const stop = () => {
    if (frame !== null) window.cancelAnimationFrame(frame);
    frame = null;
    lastTime = null;
  };
  const start = () => {
    if (frame === null && !paused && !motionPreference.matches && !document.hidden) {
      frame = window.requestAnimationFrame(tick);
    }
  };
  const syncMotion = () => {
    stop();
    toggle.disabled = motionPreference.matches;
    if (motionPreference.matches) {
      render(duration);
      glyph.textContent = '—';
      playLabel.textContent = '静态';
      toggle.setAttribute('aria-label', '已按减少动态效果设置显示静态演示');
      toggle.setAttribute('aria-pressed', 'false');
      document.querySelectorAll('.reveal.pending').forEach(element => element.classList.remove('pending'));
    } else {
      glyph.textContent = paused ? '▶' : 'Ⅱ';
      playLabel.textContent = paused ? '播放' : '暂停';
      toggle.setAttribute('aria-label', paused ? '播放演示' : '暂停演示');
      toggle.setAttribute('aria-pressed', String(paused));
      render(elapsed);
      start();
    }
  };
  toggle.addEventListener('click', () => {
    paused = !paused;
    syncMotion();
  });
  motionPreference.addEventListener('change', syncMotion);
  document.addEventListener('visibilitychange', () => document.hidden ? stop() : start());
  syncMotion();

  const copyButton = document.getElementById('copy-install');
  const command = document.getElementById('install-command');
  const copyStatus = document.getElementById('copy-status');
  copyButton.addEventListener('click', async () => {
    const text = command.textContent.trim();
    let copied = false;
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        copied = true;
      }
    } catch (_) {
      // file:// 或浏览器权限可能不支持 Clipboard API，改用本地选择复制。
    }
    if (!copied) {
      const range = document.createRange();
      range.selectNodeContents(command);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      try { copied = document.execCommand('copy'); } catch (_) { copied = false; }
      if (copied) selection.removeAllRanges();
    }
    copyButton.textContent = copied ? '已复制' : '手动复制';
    copyStatus.textContent = copied ? '安装命令已复制。' : '命令已选中，请按 ⌘C，或右键复制。';
  });
})();
