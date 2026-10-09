/* Демонстрация работает только с вымышленным текстом. Аудио и микрофон не используются. */
(() => {
  'use strict';
  document.documentElement.classList.add('js');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const data = [
    {start:0,end:12,speaker:1,text:'Давайте обсудим план. Нам нужно подготовить встречу и собрать предложения команды.'},
    {start:14,end:26,speaker:2,text:'Я предлагаю начать с короткого списка задач. Так каждому будет понятно, за что он отвечает.'},
    {start:27,end:40,speaker:1,text:'Хорошо. После встречи сохраним договорённости и разошлём участникам готовый текст.'},
    {start:42,end:52,speaker:2,text:'Да, и отметим сроки. Первый вариант можно подготовить к пятнице.'},
    {start:54,end:62,speaker:1,text:'Тогда я займусь планом встречи, а ты соберёшь вопросы от команды.'},
    {start:63,end:72,speaker:2,text:'Договорились. Если появятся дополнения, внесём их в общий документ.'}
  ];
  const transcript = document.getElementById('transcript');
  const timeline = document.getElementById('timeline');
  const playButton = document.getElementById('demo-play');
  const feedback = document.getElementById('demo-feedback');
  let elapsed = 0, mode = 'speakers', playing = false, lastFrame = null, playFrame = null, active = -1;
  const names = () => [document.getElementById('name-1').value.trim() || 'Спикер 1', document.getElementById('name-2').value.trim() || 'Спикер 2'];
  const clock = (value, full = false) => {
    const n = Math.max(0, Math.floor(value));
    const base = `${String(Math.floor(n / 60) % 60).padStart(2,'0')}:${String(n % 60).padStart(2,'0')}`;
    return full ? `${String(Math.floor(n / 3600)).padStart(2,'0')}:${base}` : base;
  };
  const subtitleClock = (value) => `${clock(value, true)},${String(Math.round((value % 1) * 1000)).padStart(3,'0')}`;
  const rows = data.map((item, index) => {
    const row = document.createElement('div');
    row.className = `transcript-row${item.speaker === 2 ? ' speaker-two' : ''}`;
    row.tabIndex = 0; row.setAttribute('role','button'); row.setAttribute('aria-label',`Перейти к реплике ${clock(item.start)}`);
    const meta = document.createElement('div'); meta.className = 'row-meta';
    const time = document.createElement('span'); time.className = 'row-time'; time.textContent = clock(item.start);
    const name = document.createElement('span'); name.className = 'row-name';
    const text = document.createElement('p'); text.textContent = item.text;
    meta.append(time,name); row.append(meta,text); transcript.append(row);
    row.addEventListener('click',() => setTime(item.start,true));
    row.addEventListener('keydown',event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setTime(item.start,true); } });
    return {row,name,index};
  });
  function updateNames() {
    const currentNames = names();
    rows.forEach(({name,index}) => { name.textContent = currentNames[data[index].speaker - 1]; });
  }
  function setMode(next) {
    mode = next;
    transcript.classList.toggle('plain',mode === 'plain');
    ['speakers','plain'].forEach(value => {
      const button = document.getElementById(`mode-${value}`);
      button.classList.toggle('active',mode === value); button.setAttribute('aria-pressed',String(mode === value));
    });
  }
  function setTime(next, scroll = false) {
    elapsed = Math.max(0,Math.min(72,Number.isFinite(next) ? next : 0));
    timeline.value = String(elapsed);
    document.getElementById('current-time').textContent = clock(elapsed);
    timeline.setAttribute('aria-valuetext',`${clock(elapsed)} из 01:12`);
    let index = 0;
    data.forEach((item,i) => { if (elapsed >= item.start) index = i; });
    if (index !== active) {
      active = index;
      rows.forEach(({row,index:i}) => { row.classList.toggle('active',i === active); row.setAttribute('aria-current',i === active ? 'true' : 'false'); });
      if (scroll) {
        const target = rows[index].row;
        transcript.scrollTo({top:Math.max(0,target.offsetTop - transcript.offsetTop - transcript.clientHeight / 2 + target.offsetHeight / 2),behavior:reducedMotion.matches ? 'instant' : 'smooth'});
      }
    }
  }
  function refreshPlay() {
    const icon = playButton.querySelector('use'); icon.setAttribute('href',playing ? '#i-pause' : '#i-play');
    playButton.setAttribute('aria-label',playing ? 'Приостановить демо' : 'Запустить демо');
    playButton.setAttribute('aria-pressed',String(playing));
  }
  function pause() { playing = false; lastFrame = null; if (playFrame !== null) cancelAnimationFrame(playFrame); playFrame = null; refreshPlay(); }
  function step(timestamp) {
    if (!playing) return;
    if (lastFrame === null) lastFrame = timestamp;
    setTime(elapsed + Math.min((timestamp - lastFrame) / 1000,.2),true);
    lastFrame = timestamp;
    if (elapsed >= 72) { pause(); return; }
    playFrame = requestAnimationFrame(step);
  }
  function play() {
    if (playing) { pause(); return; }
    if (elapsed >= 72) setTime(0,true);
    playing = true; lastFrame = null; refreshPlay(); playFrame = requestAnimationFrame(step);
  }
  timeline.addEventListener('input',() => setTime(Number(timeline.value),true));
  playButton.addEventListener('click',play);
  document.getElementById('mode-speakers').addEventListener('click',() => setMode('speakers'));
  document.getElementById('mode-plain').addEventListener('click',() => setMode('plain'));
  ['name-1','name-2'].forEach(id => document.getElementById(id).addEventListener('input',updateNames));
  document.getElementById('reset-demo').addEventListener('click',() => {
    pause(); document.getElementById('name-1').value = 'Алексей'; document.getElementById('name-2').value = 'Марина';
    updateNames(); setMode('speakers'); active = -1; setTime(0,true); feedback.textContent = 'Исходное демо восстановлено';
  });
  function bodyText() {
    const currentNames = names();
    return data.map(item => `[${clock(item.start,true)}] ${mode === 'speakers' ? currentNames[item.speaker - 1] + ': ' : ''}${item.text}`).join('\n\n');
  }
  function exportText(format) {
    if (format === 'srt') return data.map((item,index) => `${index + 1}\n${subtitleClock(item.start)} --> ${subtitleClock(item.end)}\n${mode === 'speakers' ? names()[item.speaker - 1] + ': ' : ''}${item.text}\n`).join('\n');
    return (format === 'md' ? '# Обсуждение проекта — демо\n\n' : '') + bodyText() + '\n';
  }
  document.getElementById('copy-demo').addEventListener('click',async () => {
    try { await navigator.clipboard.writeText(bodyText()); feedback.textContent = 'Текст демо скопирован'; }
    catch { feedback.textContent = 'Копирование недоступно. Сохраните пример через экспорт.'; }
  });
  document.getElementById('export-demo').addEventListener('click',() => {
    const format = document.getElementById('export-format').value;
    const url = URL.createObjectURL(new Blob([exportText(format)],{type:format === 'md' ? 'text/markdown;charset=utf-8' : 'text/plain;charset=utf-8'}));
    const link = document.createElement('a'); link.href = url; link.download = `golosa-demo.${format}`;
    document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url),10000);
    feedback.textContent = `Демо сохранено в ${format.toUpperCase()}`;
  });
  const modelInfo = document.getElementById('model-info');
  const models = {
    gigaam:{tag:'РУССКИЙ ЯЗЫК',title:'Для русскоязычных разговоров.',text:'Модель с пунктуацией для встреч, интервью и повседневной речи на русском.'},
    parakeet:{tag:'МНОГОЯЗЫЧНАЯ РЕЧЬ',title:'Когда разговор меняет язык.',text:'Модель с пунктуацией для многоязычной речи. Ожидаемый язык можно указать в приложении; сомнительные слова стоит проверить.'}
  };
  document.querySelectorAll('[data-model]').forEach(button => button.addEventListener('click',() => {
    document.querySelectorAll('[data-model]').forEach(item => { const selected = item === button; item.classList.toggle('active',selected); item.setAttribute('aria-pressed',String(selected)); });
    const model = models[button.dataset.model]; modelInfo.querySelector('.model-tag').textContent = model.tag; modelInfo.querySelector('h3').textContent = model.title; modelInfo.querySelector('p').textContent = model.text;
  }));
  const dialog = document.getElementById('screenshot-dialog');
  document.getElementById('show-screenshot').addEventListener('click',() => dialog.showModal());
  document.getElementById('close-screenshot').addEventListener('click',() => dialog.close());
  dialog.addEventListener('click',event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
  const reveal = new IntersectionObserver(entries => entries.forEach(entry => { if (entry.isIntersecting) { entry.target.classList.add('is-visible'); reveal.unobserve(entry.target); } }),{threshold:.08});
  document.querySelectorAll('.reveal').forEach(section => reveal.observe(section));
  const scene = document.getElementById('signal-scene');
  scene.addEventListener('pointermove',event => {
    if (reducedMotion.matches || event.pointerType === 'touch') return;
    const r = scene.getBoundingClientRect(),x = (event.clientX-r.left)/r.width-.5,y = (event.clientY-r.top)/r.height-.5;
    scene.style.setProperty('--rx',`${-y*7}deg`); scene.style.setProperty('--ry',`${x*8-5}deg`);
  },{passive:true});
  scene.addEventListener('pointerleave',() => { scene.style.setProperty('--rx','0deg'); scene.style.setProperty('--ry','-5deg'); });
  const canvas = document.getElementById('wave'),ctx = canvas.getContext('2d');
  let width = 1,height = 1,waveFrame = null,sceneVisible = true;
  function drawWave(time = 0) {
    if (!ctx) return;
    ctx.clearRect(0,0,width,height);
    const count = 64,space = width/count,t = reducedMotion.matches ? .5 : time/1000;
    const gradient = ctx.createLinearGradient(0,0,width,0); gradient.addColorStop(0,'#86b7eb'); gradient.addColorStop(.4,'#3266d2'); gradient.addColorStop(1,'#b199e3');
    ctx.strokeStyle = gradient; ctx.lineWidth = Math.max(2,space*.43); ctx.lineCap = 'round';
    for (let i=0;i<count;i++) {
      const x = (i+.5)*space,n = i/(count-1),envelope = Math.sin(n*Math.PI)**1.2;
      const signal = .3+.7*Math.abs(Math.sin(i*.47+t*2.2+elapsed*.12)*Math.cos(i*.17-t*.7));
      const amp = 3 + envelope*signal*height*.34;
      ctx.beginPath(); ctx.moveTo(x,height/2-amp); ctx.lineTo(x,height/2+amp); ctx.stroke();
    }
  }
  function waveLoop(time) { waveFrame = null; drawWave(time); if (sceneVisible && !document.hidden && !reducedMotion.matches) waveFrame = requestAnimationFrame(waveLoop); }
  function ensureWave() { if (waveFrame === null && sceneVisible && !document.hidden && !reducedMotion.matches) waveFrame = requestAnimationFrame(waveLoop); else if (reducedMotion.matches) drawWave(); }
  new ResizeObserver(() => {
    width = canvas.clientWidth; height = canvas.clientHeight; const scale = Math.min(window.devicePixelRatio || 1,2);
    canvas.width = Math.round(width*scale); canvas.height = Math.round(height*scale); ctx?.setTransform(scale,0,0,scale,0,0); drawWave(); ensureWave();
  }).observe(canvas);
  new IntersectionObserver(entries => { sceneVisible = entries[0].isIntersecting; ensureWave(); },{threshold:0}).observe(scene);
  reducedMotion.addEventListener('change',ensureWave);
  document.addEventListener('visibilitychange',() => { if (document.hidden) pause(); else ensureWave(); });
  updateNames(); setTime(0); refreshPlay();
})();
