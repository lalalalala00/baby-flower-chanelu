// 강아지 상태 머신. 스프라이트 시트는 8칸 × 11줄, 프레임 110×145.
(function () {
  const vscode = acquireVsCodeApi();
  const { sheet, config: initialConfig } = window.__PUP__;
  const FW = 110, FH = 145, COLS = 8;

  // 줄 번호 → 동작
  const ROW = {
    idle: 0,      // 서 있기 (눈 깜빡)
    look: 1,      // 두리번
    happy: 2,     // 혀 내밀고 웃기
    wave: 3,      // 손 흔들기
    hop: 4,       // 깡충
    walkRight: 5,
    walkLeft: 6,
    beg: 7,       // 두 발로 서기
    sit: 8,       // 앉아서 웃기
    sitBlink: 9,  // 앉아서 윙크
    sleep: 10,    // 0~3: 눕기, 4~7: 자기
  };

  const stage = document.getElementById('stage');
  const pup = document.getElementById('pup');

  let cfg = initialConfig;
  let scale = 1, w = 0, h = 0;
  let x = 0;
  let lastInput = Date.now();

  // 현재 동작
  let anim = null; // { row, frames:[...], ms, loop, onDone }
  let frameIdx = 0, frameTime = 0;
  let mode = 'idle'; // idle | walk | sleeping | busy
  let target = 0, dir = 1;
  let restUntil = 0;

  function applySize() {
    scale = cfg.size / FH;
    w = FW * scale; h = FH * scale;
    pup.style.width = w + 'px';
    pup.style.height = h + 'px';
    pup.style.backgroundImage = `url("${sheet}")`;
    pup.style.backgroundSize = `${FW * COLS * scale}px auto`;
    stage.style.minHeight = (h + 12) + 'px';
    clampX();
  }

  function stageWidth() { return stage.clientWidth || 200; }
  function clampX() { x = Math.max(0, Math.min(x, stageWidth() - w)); }

  function setFrame(row, col) {
    pup.style.backgroundPosition = `${-col * FW * scale}px ${-row * FH * scale}px`;
  }

  const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => a + i);
  const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

  function play(row, { frames = range(0, 7), ms = 140, loop = false, onDone } = {}) {
    anim = { row, frames, ms, loop, onDone };
    frameIdx = 0; frameTime = 0;
    setFrame(row, frames[0]);
  }

  // ---- 상태 전환 ----
  function startIdle() {
    mode = 'idle';
    const row = pick([ROW.idle, ROW.idle, ROW.look, ROW.happy, ROW.sit, ROW.sitBlink]);
    restUntil = performance.now() + 2000 + Math.random() * 4000;
    play(row, { ms: 160, loop: true });
  }

  function startWalk() {
    mode = 'walk';
    const max = Math.max(0, stageWidth() - w);
    target = Math.random() * max;
    if (Math.abs(target - x) < 30) target = x < max / 2 ? max : 0;
    dir = target > x ? 1 : -1;
    play(dir > 0 ? ROW.walkRight : ROW.walkLeft, { ms: 100, loop: true });
  }

  function trick(row, then = startIdle) {
    mode = 'busy';
    play(row, { ms: 110, onDone: then });
  }

  function fallAsleep() {
    if (mode === 'sleeping') return;
    mode = 'busy';
    play(ROW.sleep, {
      frames: range(0, 4), ms: 220,
      onDone: () => { mode = 'sleeping'; play(ROW.sleep, { frames: range(4, 7), ms: 450, loop: true }); },
    });
  }

  function wakeUp(then) {
    if (mode !== 'sleeping') { then(); return; }
    mode = 'busy';
    play(ROW.sleep, { frames: [3, 2, 1, 0], ms: 150, onDone: then });
  }

  // ---- 효과 ----
  function popup(cls, text) {
    const el = document.createElement('div');
    el.className = cls;
    el.textContent = text;
    el.style.left = (x + w / 2 - 6 + (Math.random() * 16 - 8)) + 'px';
    el.style.bottom = (h - 4) + 'px';
    stage.appendChild(el);
    setTimeout(() => el.remove(), 2500);
  }

  // ---- 입력 ----
  pup.addEventListener('click', () => {
    lastInput = Date.now();
    popup('heart', '❤️');
    wakeUp(() => trick(pick([ROW.hop, ROW.wave, ROW.beg, ROW.happy])));
  });

  window.addEventListener('message', (e) => {
    const msg = e.data;
    if (msg.type === 'config') { cfg = msg.config; applySize(); return; }
    if (msg.type === 'sleep') { fallAsleep(); return; }
    lastInput = Date.now();
    if (msg.type === 'pet') { popup('heart', '❤️'); wakeUp(() => trick(ROW.wave)); }
    else if (msg.type === 'saved') { wakeUp(() => trick(ROW.hop)); }
    else if (msg.type === 'typing' && mode === 'sleeping') { wakeUp(startIdle); }
  });

  window.addEventListener('resize', clampX);

  // ---- 루프 ----
  let prev = performance.now();
  let zzzTimer = 0;
  function tick(now) {
    const dt = Math.min(100, now - prev);
    prev = now;

    // 프레임 진행
    if (anim) {
      frameTime += dt;
      while (frameTime >= anim.ms) {
        frameTime -= anim.ms;
        frameIdx++;
        if (frameIdx >= anim.frames.length) {
          if (anim.loop) frameIdx = 0;
          else {
            const done = anim.onDone;
            frameIdx = anim.frames.length - 1;
            anim = { ...anim, onDone: null, ms: Infinity };
            setFrame(anim.row, anim.frames[frameIdx]);
            if (done) done();
            break;
          }
        }
        setFrame(anim.row, anim.frames[frameIdx]);
      }
    }

    // 행동
    const sleepMs = (cfg.sleepAfterSeconds || 0) * 1000;
    if (sleepMs > 0 && mode !== 'sleeping' && mode !== 'busy' && Date.now() - lastInput > sleepMs) {
      fallAsleep();
    } else if (mode === 'walk') {
      x += dir * cfg.speed * (dt / 1000);
      if ((dir > 0 && x >= target) || (dir < 0 && x <= target)) { x = target; startIdle(); }
      clampX();
    } else if (mode === 'idle' && now > restUntil) {
      Math.random() < 0.75 ? startWalk() : startIdle();
    } else if (mode === 'sleeping') {
      zzzTimer += dt;
      if (zzzTimer > 1600) { zzzTimer = 0; popup('zzz', 'z'); }
    }

    pup.style.transform = `translateX(${x}px)`;
    requestAnimationFrame(tick);
  }

  applySize();
  x = Math.random() * Math.max(0, stageWidth() - w);
  startIdle();
  requestAnimationFrame(tick);
  vscode.setState({});
})();
