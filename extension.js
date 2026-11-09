// @ts-check
const vscode = require('vscode');
const net = require('net');
const os = require('os');
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

/** @type {Desktop | undefined} */
let desktop;

/** @param {vscode.ExtensionContext} context */
function activate(context) {
  const provider = new PupViewProvider(context.extensionUri);
  desktop = new Desktop(context.extensionPath);

  /** 사이드바 패널은 기본 반응만 알아들어서 비슷한 걸로 바꿔 보내요 */
  const SIDEBAR = { work: 'typing', done: 'saved', attention: 'pet' };

  /** 사이드바와 화면 위 chanelu 둘 다에게 알려요 */
  const tell = (/** @type {'pet'|'sleep'|'typing'|'saved'|'work'|'done'|'attention'} */ type) => {
    provider.post({ type: SIDEBAR[/** @type {keyof typeof SIDEBAR} */ (type)] ?? type });
    desktop?.send(type);
  };

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('chanelu.view', provider, {
      webviewOptions: { retainContextWhenHidden: true },
    }),
    vscode.commands.registerCommand('chanelu.pet', () => tell('pet')),
    vscode.commands.registerCommand('chanelu.sleep', () => tell('sleep')),
    vscode.commands.registerCommand('chanelu.toggleDesktop', () => {
      const c = vscode.workspace.getConfiguration('chanelu');
      c.update('showOnDesktop', !c.get('showOnDesktop', true), vscode.ConfigurationTarget.Global);
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration('chanelu')) return;
      provider.post({ type: 'config', config: readConfig() });
      desktop?.sync();
    }),
  );

  // 타이핑하면 깨어나요 (초당 최대 1번만 알림)
  let lastTyping = 0;
  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.uri.scheme === 'output' || e.contentChanges.length === 0) return;
      const now = Date.now();
      if (now - lastTyping < 1000) return;
      lastTyping = now;
      tell('typing');
    }),
    vscode.workspace.onDidSaveTextDocument(() => tell('saved')),
  );

  // Claude, Codex 같은 AI 도구는 편집기를 거치지 않고 디스크에 바로 써요.
  // 워크스페이스 파일이 바뀌면 "일하는 중"으로 알려요. 빌드 결과물·의존성 폴더는 계속 바뀌니까 빼요.
  const IGNORED = /[\\/](\.git|node_modules|\.next|dist|build|out|\.turbo|\.cache|coverage|\.vercel|\.svelte-kit|target|__pycache__|\.venv)[\\/]/;
  let lastWork = 0;
  /** @param {vscode.Uri} uri */
  const onDiskChange = (uri) => {
    if (IGNORED.test(uri.fsPath)) return;
    const now = Date.now();
    if (now - lastWork < 1500) return;
    lastWork = now;
    tell('work');
  };
  const watcher = vscode.workspace.createFileSystemWatcher('**/*');
  context.subscriptions.push(watcher, watcher.onDidChange(onDiskChange), watcher.onDidCreate(onDiskChange));

  desktop.sync();
}

function readConfig() {
  const c = vscode.workspace.getConfiguration('chanelu');
  return {
    size: c.get('size', 72),
    speed: c.get('speed', 40),
    sleepAfterSeconds: c.get('sleepAfterSeconds', 120),
    showOnDesktop: c.get('showOnDesktop', true),
    desktopSize: c.get('desktopSize', 96),
  };
}

/**
 * 화면 위 chanelu (맥 전용 프로그램 bin/chanelu-desktop) 연결 관리.
 * VS Code 창이 여러 개여도 프로그램은 하나만 떠 있고, 각 창이 같은 소켓으로 접속해요.
 * 모든 창이 닫혀 연결이 끊기면 프로그램은 스스로 종료해요.
 */
class Desktop {
  /** @param {string} extensionPath */
  constructor(extensionPath) {
    this.version = require(path.join(extensionPath, 'package.json')).version;
    this.bin = path.join(extensionPath, 'bin', 'chanelu-desktop');
    this.sheet = path.join(extensionPath, 'media', 'sheet.png');
    this.sockPath = `/tmp/chanelu-${os.userInfo().uid}.sock`;
    /** @type {net.Socket | null} */
    this.sock = null;
    this.enabled = false;
    /** @type {NodeJS.Timeout | undefined} */
    this.timer = undefined;
    this.warned = false;
  }

  configLine() {
    const c = readConfig();
    return `config ${c.desktopSize} ${Math.round(c.speed * 1.5)} ${c.sleepAfterSeconds}`;
  }

  /** 설정에 맞춰 켜고 끄고, 켜져 있으면 설정값을 보내요 */
  sync() {
    const want = process.platform === 'darwin' && readConfig().showOnDesktop;
    if (want && !this.enabled) {
      this.enabled = true;
      this.connect(0);
    } else if (!want && this.enabled) {
      this.enabled = false;
      clearTimeout(this.timer);
      if (this.sock) this.sock.end('quit\n');
      this.sock = null;
    } else if (want) {
      this.send(this.configLine());
    }
  }

  /** @param {string} line */
  send(line) {
    if (this.sock && !this.sock.destroyed) this.sock.write(line + '\n');
  }

  /** @param {number} attempt */
  connect(attempt) {
    if (!this.enabled || this.sock) return;
    const s = net.createConnection(this.sockPath);
    s.on('connect', () => {
      if (!this.enabled) { s.destroy(); return; }
      this.sock = s;
      s.write(this.configLine() + '\n');
      this.checkVersion(s);
    });
    s.on('error', () => {
      s.destroy();
      if (!this.enabled || this.sock === s) return;
      if (attempt === 0) this.spawn();
      if (attempt < 20) this.timer = setTimeout(() => this.connect(attempt + 1), 250);
    });
    s.on('close', () => {
      if (this.sock !== s) return;
      this.sock = null;
      // 다른 창이 끄거나 프로그램이 죽었으면 잠시 뒤 다시 연결 (꺼진 상태면 안 함)
      if (this.enabled) this.timer = setTimeout(() => this.connect(0), 2000);
    });
  }

  /**
   * 떠 있는 샤네루가 이 확장보다 예전 버전이면 새 버전으로 바꿔 띄워요.
   * (예전 샤네루는 새 신호를 몰라서, 확장을 업데이트해도 반응이 안 바뀌던 문제)
   * 0.2.4 이하는 버전 질문에 답을 못 해요 → 답이 없으면 예전 버전으로 봐요.
   * 맥 앱(혼자 실행)은 quit을 무시하니까 앱 샤네루는 그대로 남아요.
   * @param {net.Socket} s
   */
  checkVersion(s) {
    let buf = '';
    let answered = false;
    const replace = () => {
      if (this.sock === s && !s.destroyed) s.write('quit\n'); // 끊기면 close 핸들러가 새 버전을 띄워요
    };
    const timer = setTimeout(() => { if (!answered) replace(); }, 1500);
    s.on('data', (chunk) => {
      buf += chunk.toString();
      const m = buf.match(/^version (\S+)/m);
      if (!m || answered) return;
      answered = true;
      clearTimeout(timer);
      if (olderThan(m[1], this.version)) replace();
    });
    s.write('version\n');
  }

  spawn() {
    const c = readConfig();
    try {
      // .vsix로 설치하면 실행 권한이 빠질 수 있어서 다시 넣어줘요
      fs.chmodSync(this.bin, 0o755);
      const child = cp.spawn(
        this.bin,
        [this.sheet, this.sockPath, String(c.desktopSize), String(Math.round(c.speed * 1.5)), String(c.sleepAfterSeconds)],
        { detached: true, stdio: 'ignore' },
      );
      child.on('error', (err) => this.warn(err));
      child.unref();
    } catch (err) {
      this.warn(err);
    }
  }

  /** @param {unknown} err */
  warn(err) {
    if (this.warned) return;
    this.warned = true;
    vscode.window.showWarningMessage(`chanelu를 화면에 띄우지 못했어요: ${err instanceof Error ? err.message : err}`);
  }

  dispose() {
    // quit은 보내지 않아요. 다른 VS Code 창이 아직 쓰고 있을 수 있어서, 마지막 연결이 끊기면 프로그램이 알아서 꺼져요.
    this.enabled = false;
    clearTimeout(this.timer);
    this.sock?.destroy();
    this.sock = null;
  }
}

class PupViewProvider {
  /** @param {vscode.Uri} extensionUri */
  constructor(extensionUri) {
    this.extensionUri = extensionUri;
    /** @type {vscode.WebviewView | undefined} */
    this.view = undefined;
  }

  /** @param {any} msg */
  post(msg) {
    this.view?.webview.postMessage(msg);
  }

  /** @param {vscode.WebviewView} view */
  resolveWebviewView(view) {
    this.view = view;
    const media = vscode.Uri.joinPath(this.extensionUri, 'media');
    view.webview.options = { enableScripts: true, localResourceRoots: [media] };

    const sheetUri = view.webview.asWebviewUri(vscode.Uri.joinPath(media, 'sheet.png'));
    const scriptUri = view.webview.asWebviewUri(vscode.Uri.joinPath(media, 'main.js'));
    const nonce = Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
    const init = JSON.stringify({ sheet: sheetUri.toString(), config: readConfig() });

    view.webview.html = /* html */ `<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${view.webview.cspSource}; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; background: transparent; user-select: none; }
  #stage { position: relative; width: 100%; height: 100%; min-height: 90px; }
  #pup { position: absolute; bottom: 4px; left: 0; background-repeat: no-repeat; cursor: pointer; will-change: transform; }
  .heart { position: absolute; font-size: 14px; pointer-events: none; animation: float 1.2s ease-out forwards; }
  .zzz { position: absolute; font-size: 12px; pointer-events: none; opacity: .7; font-family: var(--vscode-font-family);
         color: var(--vscode-foreground); animation: float 2.4s ease-out forwards; }
  @keyframes float { from { transform: translateY(0); opacity: 1; } to { transform: translateY(-36px); opacity: 0; } }
</style>
</head>
<body>
<div id="stage"><div id="pup" title="Chanelu ❤"></div></div>
<script nonce="${nonce}">window.__PUP__ = ${init};</script>
<script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
  }
}

/** "0.2.5" < "0.2.6" 같은 버전 비교 */
function olderThan(/** @type {string} */ a, /** @type {string} */ b) {
  const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) < (pb[i] || 0);
  }
  return false;
}

function deactivate() {
  desktop?.dispose();
}

module.exports = { activate, deactivate };
