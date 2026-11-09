// 베이비 플라워 샤네루 — 윈도우용 데스크톱 펫
// 작업 표시줄 위를 돌아다녀요. 클릭하면 반응하고, 드래그해서 들어 올릴 수 있고,
// 키보드·마우스를 한동안 안 쓰면 잠들어요. 트레이 아이콘 메뉴로 크기·잠들기·시작 시 실행·종료를 바꿔요.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Chanelu
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            // 한 번에 한 마리만
            using (var mutex = new Mutex(true, @"Local\BabyFlowerChanelu", out bool created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new PupForm());
            }
        }
    }

    enum Row { Idle = 0, Look, Happy, Wave, Hop, WalkRight, WalkLeft, Beg, Sit, SitBlink, Sleep }

    enum Mode { Idle, Walk, Busy, Sleeping, Dragging, Falling }

    class Anim
    {
        public Row Row;
        public int[] Frames;
        public double Dur;
        public bool Loop;
        public Action OnDone;
    }

    class Particle
    {
        public string Text;
        public Color Color;
        public float X;
        public double Age;
        public double Life;
    }

    /// <summary>%APPDATA%\Chanelu\settings.txt 에 key=value 로 저장</summary>
    class Settings
    {
        public int Size = 96;
        public int SleepAfter = 120;

        static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Chanelu", "settings.txt");

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                foreach (var line in File.ReadAllLines(FilePath))
                {
                    var kv = line.Split('=');
                    if (kv.Length != 2 || !int.TryParse(kv[1].Trim(), out int v)) continue;
                    if (kv[0].Trim() == "size") s.Size = Math.Max(40, Math.Min(300, v));
                    if (kv[0].Trim() == "sleep") s.SleepAfter = Math.Max(0, v);
                }
            }
            catch { /* 처음 실행 */ }
            return s;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                File.WriteAllText(FilePath, $"size={Size}\nsleep={SleepAfter}\n");
            }
            catch { }
        }
    }

    class PupForm : Form
    {
        const int FW = 110, FH = 145, COLS = 8, ROWS = 11;
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "BabyFlowerChanelu";

        readonly Settings settings = Settings.Load();
        readonly Bitmap sheet;
        readonly Random rnd = new Random();
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly List<Particle> particles = new List<Particle>();
        readonly float dpi;
        readonly Font particleFont;

        Bitmap[] frames = new Bitmap[ROWS * COLS];
        int w, h, headroom, cw, ch;
        float x, footY, vy, target, dir = 1;
        float speed;
        Mode mode = Mode.Idle;
        Anim anim;
        int fi;
        double ft, prev, restUntil, lastInput, zzz;
        Point pressAt, dragOffset;
        bool pressed, dragMoved;

        public PupForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            Text = "Baby Flower Chanelu";

            using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpi = g.DpiX / 96f;
            particleFont = new Font("Segoe UI Symbol", 15f * dpi, FontStyle.Bold, GraphicsUnit.Pixel);
            speed = 60f * dpi;

            using (var s = typeof(PupForm).Assembly.GetManifestResourceStream("sheet.png"))
                sheet = new Bitmap(s);
            ApplySize();

            var wa = Screen.PrimaryScreen.WorkingArea;
            x = wa.Left + (float)rnd.NextDouble() * Math.Max(1, wa.Width - w);
            footY = wa.Bottom;
            prev = Now;
            lastInput = Now;
            StartIdle();

            SetupTray();

            timer.Interval = 15;
            timer.Tick += (_, __) => Tick();
            timer.Start();
        }

        double Now => clock.Elapsed.TotalSeconds;

        // ---- 창 스타일: 투명, 항상 위, 작업 표시줄에 안 뜸, 포커스 안 뺏음 ----
        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST | Native.WS_EX_NOACTIVATE;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation => true;

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            Render();
        }

        // ---- 크기 ----
        void ApplySize()
        {
            h = (int)Math.Round(settings.Size * dpi);
            w = (int)Math.Round(FW * (float)h / FH);
            headroom = (int)Math.Round(44 * dpi);
            cw = w;
            ch = h + headroom;
            foreach (var f in frames) f?.Dispose();
            for (int r = 0; r < ROWS; r++)
                for (int c = 0; c < COLS; c++)
                {
                    var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(bmp))
                    {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.CompositingQuality = CompositingQuality.HighQuality;
                        g.DrawImage(sheet, new Rectangle(0, 0, w, h), new Rectangle(c * FW, r * FH, FW, FH), GraphicsUnit.Pixel);
                    }
                    frames[r * COLS + c] = bmp;
                }
        }

        // ---- 애니메이션 ----
        static int[] Range(int a, int b) => Enumerable.Range(a, b - a + 1).ToArray();

        void Play(Row row, int[] f = null, double dur = 0.14, bool loop = false, Action onDone = null)
        {
            anim = new Anim { Row = row, Frames = f ?? Range(0, 7), Dur = dur, Loop = loop, OnDone = onDone };
            fi = 0;
            ft = 0;
        }

        void Advance(double dt)
        {
            if (anim == null) return;
            ft += dt;
            while (ft >= anim.Dur)
            {
                ft -= anim.Dur;
                fi++;
                if (fi >= anim.Frames.Length)
                {
                    if (anim.Loop) { fi = 0; continue; }
                    fi = anim.Frames.Length - 1;
                    var done = anim.OnDone;
                    anim.OnDone = null;
                    anim.Dur = double.PositiveInfinity;
                    done?.Invoke();
                    return;
                }
            }
        }

        // ---- 상태 ----
        void StartIdle()
        {
            mode = Mode.Idle;
            var rows = new[] { Row.Idle, Row.Idle, Row.Look, Row.Happy, Row.Sit, Row.SitBlink };
            restUntil = Now + 2 + rnd.NextDouble() * 5;
            Play(rows[rnd.Next(rows.Length)], dur: 0.16, loop: true);
        }

        void StartWalk()
        {
            mode = Mode.Walk;
            var here = ScreenAt(x + w / 2f, footY);
            var wa = here.WorkingArea;
            // 가로로 붙은 옆 모니터가 있으면 가끔(25%) 놀러 가요
            var neighbors = Screen.AllScreens.Where(s => !s.Equals(here) &&
                (Math.Abs(s.Bounds.Left - here.Bounds.Right) < 2 || Math.Abs(s.Bounds.Right - here.Bounds.Left) < 2)).ToArray();
            if (neighbors.Length > 0 && rnd.NextDouble() < 0.25)
            {
                var n = neighbors[rnd.Next(neighbors.Length)].WorkingArea;
                target = n.Left + (float)rnd.NextDouble() * Math.Max(1, n.Width - w);
            }
            else
            {
                float maxX = wa.Right - w;
                target = wa.Left + (float)rnd.NextDouble() * Math.Max(1, maxX - wa.Left);
                if (Math.Abs(target - x) < 60 * dpi)
                    target = x < (wa.Left + maxX) / 2 ? Math.Min(maxX, x + 300 * dpi) : Math.Max(wa.Left, x - 300 * dpi);
            }
            dir = target > x ? 1 : -1;
            Play(dir > 0 ? Row.WalkRight : Row.WalkLeft, dur: 0.1, loop: true);
        }

        void Trick(Row row)
        {
            mode = Mode.Busy;
            Play(row, dur: 0.11, onDone: StartIdle);
        }

        void FallAsleep()
        {
            if (mode == Mode.Sleeping || mode == Mode.Dragging || mode == Mode.Falling) return;
            mode = Mode.Busy;
            Play(Row.Sleep, Range(0, 4), 0.22, onDone: () =>
            {
                mode = Mode.Sleeping;
                Play(Row.Sleep, Range(4, 7), 0.45, loop: true);
            });
        }

        void WakeUp(Action then)
        {
            if (mode != Mode.Sleeping) { then(); return; }
            mode = Mode.Busy;
            Play(Row.Sleep, new[] { 3, 2, 1, 0 }, 0.15, onDone: then);
        }

        void Pet()
        {
            lastInput = Now;
            Popup("♥", Color.FromArgb(235, 87, 120), 1.2);
            var tricks = new[] { Row.Hop, Row.Wave, Row.Beg, Row.Happy };
            WakeUp(() => Trick(tricks[rnd.Next(tricks.Length)]));
        }

        void Popup(string text, Color color, double life)
        {
            particles.Add(new Particle
            {
                Text = text,
                Color = color,
                X = w / 2f - 8 * dpi + (float)(rnd.NextDouble() * 16 - 8) * dpi,
                Life = life,
            });
        }

        // ---- 화면 ----
        /// 발 위치(cx, footY)가 속한 화면. 위아래로 겹치면 발 아래 바닥이 있는 화면.
        Screen ScreenAt(float cx, float fy)
        {
            var all = Screen.AllScreens;
            var hits = all.Where(s => s.Bounds.Left <= cx && cx < s.Bounds.Right).ToList();
            var below = hits.Where(s => s.WorkingArea.Bottom >= fy - 1).OrderBy(s => s.WorkingArea.Bottom).FirstOrDefault();
            if (below != null) return below;
            if (hits.Count > 0) return hits.OrderBy(s => Math.Abs(s.WorkingArea.Bottom - fy)).First();
            return all.OrderBy(s => cx < s.Bounds.Left ? s.Bounds.Left - cx : cx >= s.Bounds.Right ? cx - s.Bounds.Right : 0).First();
        }

        // ---- 매 프레임 ----
        void Tick()
        {
            double now = Now;
            double dt = Math.Min(0.1, now - prev);
            prev = now;
            Advance(dt);

            if (mode == Mode.Walk)
            {
                x += dir * speed * (float)dt;
                if ((dir > 0 && x >= target) || (dir < 0 && x <= target)) { x = target; StartIdle(); }
            }

            var wa = ScreenAt(x + w / 2f, footY).WorkingArea;
            switch (mode)
            {
                case Mode.Idle:
                    if (now > restUntil) { if (rnd.NextDouble() < 0.7) StartWalk(); else StartIdle(); }
                    break;
                case Mode.Sleeping:
                    zzz += dt;
                    if (zzz > 1.6) { zzz = 0; Popup("z", Color.FromArgb(150, 150, 150), 2.2); }
                    break;
                case Mode.Falling:
                    vy += 2400 * dpi * (float)dt;
                    footY += vy * (float)dt;
                    if (footY >= wa.Bottom) { footY = wa.Bottom; vy = 0; Trick(Row.Hop); }
                    break;
            }

            // 키보드·마우스를 쓴 시각 기준으로 자고 깨요
            double idle = Native.IdleSeconds();
            lastInput = Math.Max(lastInput, now - idle);
            if (mode == Mode.Sleeping && idle < 0.5) WakeUp(StartIdle);
            if (settings.SleepAfter > 0 && (mode == Mode.Idle || mode == Mode.Walk) && now - lastInput > settings.SleepAfter) FallAsleep();

            if (mode != Mode.Dragging)
            {
                if (mode != Mode.Falling) footY = wa.Bottom;
                if (mode == Mode.Walk)
                {
                    var all = Screen.AllScreens;
                    x = Math.Max(all.Min(s => s.WorkingArea.Left), Math.Min(x, all.Max(s => s.WorkingArea.Right) - w));
                }
                else
                {
                    x = Math.Max(wa.Left, Math.Min(x, wa.Right - w));
                }
            }

            for (int i = particles.Count - 1; i >= 0; i--)
            {
                particles[i].Age += dt;
                if (particles[i].Age >= particles[i].Life) particles.RemoveAt(i);
            }

            Render();
        }

        // ---- 그리기: 픽셀 단위 투명도를 살려서 UpdateLayeredWindow ----
        void Render()
        {
            if (!IsHandleCreated || anim == null) return;
            using (var bmp = new Bitmap(cw, ch, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.Transparent);
                    g.CompositingMode = CompositingMode.SourceOver;
                    g.DrawImageUnscaled(frames[(int)anim.Row * COLS + anim.Frames[fi]], 0, ch - h);
                    g.TextRenderingHint = TextRenderingHint.AntiAlias;
                    foreach (var p in particles)
                    {
                        double t = p.Age / p.Life;
                        float rise = (float)(34 * dpi * (1 - Math.Pow(1 - t, 2)));
                        int a = (int)(255 * (1 - t));
                        using (var b = new SolidBrush(Color.FromArgb(Math.Max(0, a), p.Color)))
                            g.DrawString(p.Text, particleFont, b, p.X, ch - h - 10 * dpi - rise);
                    }
                }
                int left = (int)Math.Round(x), top = (int)Math.Round(footY) - ch;
                Native.SetLayeredBitmap(Handle, bmp, left, top);
            }
        }

        // ---- 마우스 ----
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Right) { menu.Show(Cursor.Position); return; }
            if (e.Button != MouseButtons.Left) return;
            pressed = true;
            dragMoved = false;
            pressAt = Cursor.Position;
            dragOffset = new Point(Cursor.Position.X - (int)x, Cursor.Position.Y - ((int)footY - ch));
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!pressed) return;
            var c = Cursor.Position;
            if (!dragMoved && Math.Abs(c.X - pressAt.X) + Math.Abs(c.Y - pressAt.Y) > 4 * dpi)
            {
                dragMoved = true;
                lastInput = Now;
                mode = Mode.Dragging;
                Play(Row.Beg, new[] { 2, 3, 4, 3 }, 0.12, loop: true);
            }
            if (dragMoved)
            {
                x = c.X - dragOffset.X;
                footY = c.Y - dragOffset.Y + ch;
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (!pressed || e.Button != MouseButtons.Left) return;
            pressed = false;
            if (dragMoved) { mode = Mode.Falling; vy = 0; }
            else Pet();
        }

        // ---- 트레이 메뉴 ----
        void SetupTray()
        {
            tray.Icon = LoadTrayIcon();
            tray.Text = "베이비 플라워 샤네루";
            tray.ContextMenuStrip = menu;
            tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) Pet(); };

            var sizeMenu = new ToolStripMenuItem("크기");
            var sleepMenu = new ToolStripMenuItem("안 움직이면 잠들기");
            var startup = new ToolStripMenuItem("윈도우 시작할 때 실행");

            void RefreshChecks()
            {
                foreach (ToolStripMenuItem i in sizeMenu.DropDownItems) i.Checked = (int)i.Tag == settings.Size;
                foreach (ToolStripMenuItem i in sleepMenu.DropDownItems) i.Checked = (int)i.Tag == settings.SleepAfter;
                startup.Checked = IsRunAtStartup();
            }

            foreach (var (name, v) in new[] { ("작게", 72), ("보통", 96), ("크게", 128), ("아주 크게", 160) })
            {
                var item = new ToolStripMenuItem(name) { Tag = v };
                item.Click += (_, __) => { settings.Size = v; settings.Save(); ApplySize(); RefreshChecks(); };
                sizeMenu.DropDownItems.Add(item);
            }
            foreach (var (name, v) in new[] { ("1분", 60), ("2분", 120), ("5분", 300), ("10분", 600), ("안 잠", 0) })
            {
                var item = new ToolStripMenuItem(name) { Tag = v };
                item.Click += (_, __) => { settings.SleepAfter = v; settings.Save(); RefreshChecks(); };
                sleepMenu.DropDownItems.Add(item);
            }
            startup.Click += (_, __) => { SetRunAtStartup(!IsRunAtStartup()); RefreshChecks(); };

            menu.Items.Add(new ToolStripMenuItem("베이비 플라워 샤네루") { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("쓰다듬기", null, (_, __) => Pet());
            menu.Items.Add("재우기", null, (_, __) => FallAsleep());
            menu.Items.Add(sizeMenu);
            menu.Items.Add(sleepMenu);
            menu.Items.Add(startup);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("종료", null, (_, __) => { tray.Visible = false; Application.Exit(); });
            menu.Opening += (_, __) => RefreshChecks();

            RefreshChecks();
            tray.Visible = true;
        }

        Icon LoadTrayIcon()
        {
            try
            {
                using (var s = typeof(PupForm).Assembly.GetManifestResourceStream("chanelu.ico"))
                    return new Icon(s, SystemInformation.SmallIconSize);
            }
            catch
            {
                // PNG 아이콘을 못 읽는 환경이면 스프라이트 첫 프레임으로
                using (var b = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
                {
                    using (var g = Graphics.FromImage(b))
                    {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.DrawImage(sheet, new Rectangle(4, 0, 24, 32), new Rectangle(0, 0, FW, FH), GraphicsUnit.Pixel);
                    }
                    return Icon.FromHandle(b.GetHicon());
                }
            }
        }

        static bool IsRunAtStartup()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
                return k?.GetValue(RunName) is string;
        }

        static void SetRunAtStartup(bool on)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue(RunName, $"\"{Application.ExecutablePath}\"");
                else k.DeleteValue(RunName, false);
            }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            tray.Visible = false;
            tray.Dispose();
            base.OnFormClosed(e);
        }
    }

    static class Native
    {
        public const int WS_EX_LAYERED = 0x00080000;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const int WS_EX_TOPMOST = 0x00000008;
        public const int WS_EX_NOACTIVATE = 0x08000000;
        const int ULW_ALPHA = 0x02;
        const byte AC_SRC_OVER = 0x00, AC_SRC_ALPHA = 0x01;

        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int CX, CY; public SIZE(int cx, int cy) { CX = cx; CY = cy; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hDC);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        public static void SetLayeredBitmap(IntPtr hwnd, Bitmap bmp, int left, int top)
        {
            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memDc = CreateCompatibleDC(screenDc);
            IntPtr hBitmap = IntPtr.Zero, old = IntPtr.Zero;
            try
            {
                hBitmap = bmp.GetHbitmap(Color.FromArgb(0)); // 알파 포함(미리 곱한) DIB
                old = SelectObject(memDc, hBitmap);
                var size = new SIZE(bmp.Width, bmp.Height);
                var src = new POINT(0, 0);
                var dst = new POINT(left, top);
                var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };
                UpdateLayeredWindow(hwnd, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, ULW_ALPHA);
            }
            finally
            {
                if (hBitmap != IntPtr.Zero) { SelectObject(memDc, old); DeleteObject(hBitmap); }
                DeleteDC(memDc);
                ReleaseDC(IntPtr.Zero, screenDc);
            }
        }

        public static double IdleSeconds()
        {
            var lii = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
            if (!GetLastInputInfo(ref lii)) return 0;
            return unchecked((uint)Environment.TickCount - lii.dwTime) / 1000.0;
        }
    }
}
