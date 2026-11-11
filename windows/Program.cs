// 꽃개 샤네루 — 윈도우용 데스크톱 펫
// 작업 표시줄 위를 돌아다녀요. 클릭하면 반응하고, 드래그해서 들어 올릴 수 있고,
// 키보드·마우스를 한동안 안 쓰면 잠들어요. 트레이 아이콘 메뉴로 크기·잠들기·시작 시 실행·종료를 바꿔요.
//
// 샤네루 말고 다른 펫도 띄울 수 있어요: pet.json + 스프라이트 시트 (docs/pet-format.md).
// 펫을 찾는 순서: 실행 인자(pet.json 경로, exe에 끌어다 놓기) → exe 옆 PetData\pet.json 또는 pet.json
// → 메뉴의 "펫 불러오기…"로 저장해 둔 펫(%APPDATA%\Chanelu\Pet) → 기본 샤네루.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace Chanelu
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            // 한 번에 한 마리만
            using (var mutex = new Mutex(true, @"Local\BabyFlowerChanelu", out bool created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                var pet = PetLoader.Find(args, out string warning);
                Application.Run(new PupForm(pet, warning));
            }
        }
    }

    enum Mode { Idle, Walk, Busy, Sleeping, Dragging, Falling }

    class Anim
    {
        public Clip Clip;
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

    /// <summary>
    /// 동작 하나. 프레임 번호는 시트를 왼쪽 위부터 가로로 읽은 순서(행 * 열개수 + 열).
    /// Dur가 null이면 동작마다 정해진 기본 속도(샤네루가 원래 움직이던 속도)를 써요.
    /// </summary>
    class Clip
    {
        public int[] Frames;
        public double? Dur;
        public bool Flip;
        public Clip Copy() => new Clip { Frames = Frames, Dur = Dur, Flip = Flip };
    }

    class PetDef
    {
        public string Name;
        public int FW, FH, Cols;
        public Bitmap Sheet;
        public Dictionary<string, Clip> Clips = new Dictionary<string, Clip>();
        public bool Builtin;
        /// <summary>pet.json이 있던 폴더 (불러오기로 저장할 때 씀)</summary>
        public string SourceDir;

        public bool Has(string n) => Clips.ContainsKey(n);
        public string First(params string[] names) => names.FirstOrDefault(Has);
    }

    class PetException : Exception { public PetException(string m) : base(m) { } }

    static class PetLoader
    {
        public static string SavedDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Chanelu", "Pet");

        public static PetDef Find(string[] args, out string warning)
        {
            warning = null;
            var tries = new List<string>();
            if (args.Length > 0 && !string.IsNullOrWhiteSpace(args[0])) tries.Add(args[0]);
            var exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            foreach (var rel in new[] { Path.Combine("PetData", "pet.json"), "pet.json" })
            {
                var p = Path.Combine(exeDir, rel);
                if (File.Exists(p)) { tries.Add(p); break; }
            }
            var saved = Path.Combine(SavedDir, "pet.json");
            if (File.Exists(saved)) tries.Add(saved);

            foreach (var p in tries)
            {
                try { return FromJson(p); }
                catch (PetException e) { warning = e.Message; }
                catch (Exception e) { warning = e.Message; }
            }
            return Chanelu();
        }

        /// <summary>기본 샤네루: 8열 x 11행, 행마다 동작 하나</summary>
        public static PetDef Chanelu()
        {
            Clip Row(int r, int[] cols = null) => new Clip { Frames = (cols ?? Enumerable.Range(0, 8).ToArray()).Select(c => r * 8 + c).ToArray() };
            Bitmap sheet;
            using (var s = typeof(PupForm).Assembly.GetManifestResourceStream("sheet.png"))
            using (var b = new Bitmap(s))
                sheet = new Bitmap(b);
            var pet = new PetDef { Name = "꽃개 샤네루", FW = 110, FH = 145, Cols = 8, Sheet = sheet, Builtin = true };
            pet.Clips["idle"] = Row(0);
            pet.Clips["look"] = Row(1);
            pet.Clips["happy"] = Row(2);
            pet.Clips["wave"] = Row(3);
            pet.Clips["jump"] = Row(4);
            pet.Clips["walkRight"] = Row(5);
            pet.Clips["walkLeft"] = Row(6);
            pet.Clips["beg"] = Row(7);
            pet.Clips["sit"] = Row(8);
            pet.Clips["sitBlink"] = Row(9);
            pet.Clips["sleepStart"] = Row(10, new[] { 0, 1, 2, 3, 4 });
            pet.Clips["sleep"] = Row(10, new[] { 4, 5, 6, 7 });
            pet.Clips["wake"] = Row(10, new[] { 3, 2, 1, 0 });
            pet.Clips["drag"] = Row(7, new[] { 2, 3, 4, 3 });
            return pet;
        }

        static double? Num(object o)
        {
            if (o == null || o is string || o is bool) return null;
            try { return Convert.ToDouble(o, CultureInfo.InvariantCulture); } catch { return null; }
        }

        static bool SafeRelative(string sprite) =>
            !string.IsNullOrEmpty(sprite) && !Path.IsPathRooted(sprite) && !sprite.Split('/', '\\').Contains("..");

        /// <summary>pet.json 읽기. 경로가 폴더면 그 안의 pet.json.</summary>
        public static PetDef FromJson(string path)
        {
            if (Directory.Exists(path)) path = Path.Combine(path, "pet.json");
            if (!File.Exists(path)) throw new PetException("pet.json을 찾을 수 없어요");
            Dictionary<string, object> j;
            try { j = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>; }
            catch { j = null; }
            if (j == null) throw new PetException("pet.json 형식이 올바르지 않아요");
            object Get(Dictionary<string, object> d, string k) => d.TryGetValue(k, out var v) ? v : null;

            var ver = Num(Get(j, "version"));
            if (ver > 1) throw new PetException("더 새 버전의 펫 파일이에요. 프로그램을 업데이트해 주세요");
            var sprite = Get(j, "sprite") as string;
            var fwD = Num(Get(j, "frameWidth"));
            var fhD = Num(Get(j, "frameHeight"));
            if (string.IsNullOrEmpty(sprite) || fwD == null || fhD == null) throw new PetException("pet.json에 sprite, frameWidth, frameHeight가 필요해요");
            int fw = (int)fwD, fh = (int)fhD;
            if (fw <= 0 || fh <= 0 || fw > 4096 || fh > 4096) throw new PetException("프레임 크기가 올바르지 않아요");
            if (!SafeRelative(sprite)) throw new PetException("sprite는 pet.json과 같은 폴더 안의 파일이어야 해요");

            var dir = Path.GetDirectoryName(Path.GetFullPath(path));
            Bitmap sheet;
            try
            {
                // 파일을 잠그지 않게 복사해서 써요
                using (var fs = File.OpenRead(Path.Combine(dir, sprite)))
                using (var b = new Bitmap(fs))
                    sheet = new Bitmap(b);
            }
            catch { throw new PetException("이미지를 읽을 수 없어요: " + Path.GetFileName(sprite)); }

            var colsD = Num(Get(j, "columns"));
            int cols = colsD != null ? (int)colsD : sheet.Width / fw;
            if (cols <= 0 || sheet.Height < fh) { sheet.Dispose(); throw new PetException("이미지가 프레임 크기보다 작아요"); }
            int total = cols * (sheet.Height / fh);

            var pet = new PetDef { FW = fw, FH = fh, Cols = cols, Sheet = sheet, SourceDir = dir };
            pet.Name = Get(j, "name") as string;
            if (string.IsNullOrWhiteSpace(pet.Name)) pet.Name = "내 펫";

            if (Get(j, "animations") is Dictionary<string, object> anims)
            {
                foreach (var kv in anims)
                {
                    if (!(kv.Value is Dictionary<string, object> a) || !(Get(a, "frames") is object[] fr)) continue;
                    var frames = fr.Select(Num).Where(v => v != null).Select(v => (int)v.Value)
                        .Where(i => i >= 0 && i < total && (i % cols + 1) * fw <= sheet.Width).ToArray();
                    if (frames.Length == 0) continue;
                    var fps = Num(Get(a, "fps"));
                    pet.Clips[kv.Key] = new Clip
                    {
                        Frames = frames,
                        Dur = fps > 0 ? 1 / Math.Min(60, fps.Value) : (double?)null,
                        Flip = Get(a, "flip") is bool f && f,
                    };
                }
            }

            // 걷기: 오른쪽/왼쪽 두 방향이 필요해요. 한쪽만 있으면 좌우를 뒤집어서 써요.
            bool facingLeft = (Get(j, "walkFacing") as string) == "left";
            pet.Clips.TryGetValue("walk", out var walk);
            pet.Clips.Remove("walk");
            pet.Clips.TryGetValue("walkRight", out var right);
            pet.Clips.TryGetValue("walkLeft", out var left);
            if (walk != null) { if (facingLeft) left = left ?? walk; else right = right ?? walk; }
            if (right == null && left != null) { right = left.Copy(); right.Flip = !right.Flip; }
            if (left == null && right != null) { left = right.Copy(); left.Flip = !left.Flip; }
            if (right != null) { pet.Clips["walkRight"] = right; pet.Clips["walkLeft"] = left; }

            // 잠들기: sleepStart(눕기) → sleep(반복) → wake(일어나기). wake가 없으면 sleepStart를 거꾸로.
            if (!pet.Has("wake") && pet.Clips.TryGetValue("sleepStart", out var ss) && ss.Frames.Length > 1)
            {
                var wake = ss.Copy();
                wake.Frames = ss.Frames.Take(ss.Frames.Length - 1).Reverse().ToArray();
                pet.Clips["wake"] = wake;
            }

            if (!pet.Has("idle"))
            {
                // 가만히 있는 동작이 없으면 아무 동작의 첫 프레임으로
                var any = pet.Clips.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => kv.Value).FirstOrDefault();
                if (any == null) { sheet.Dispose(); throw new PetException("시트 안에 있는 프레임이 하나도 없어요. 프레임 크기와 번호를 확인해 주세요"); }
                pet.Clips["idle"] = new Clip { Frames = new[] { any.Frames[0] }, Flip = any.Flip };
            }
            return pet;
        }

        /// <summary>불러온 펫(pet.json + 시트)을 %APPDATA%\Chanelu\Pet 에 복사해 두고, 다음 실행부터 그 펫을 써요.</summary>
        public static void Save(string dir)
        {
            var json = Path.Combine(dir, "pet.json");
            var j = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(json)) as Dictionary<string, object>;
            var sprite = j != null && j.TryGetValue("sprite", out var sp) ? sp as string : null;
            if (!SafeRelative(sprite)) throw new PetException("pet.json을 읽을 수 없어요");
            var tmp = SavedDir + ".tmp";
            if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
            var dst = Path.Combine(tmp, sprite);
            Directory.CreateDirectory(Path.GetDirectoryName(dst));
            File.Copy(json, Path.Combine(tmp, "pet.json"));
            File.Copy(Path.Combine(dir, sprite), dst);
            if (Directory.Exists(SavedDir)) Directory.Delete(SavedDir, true);
            Directory.Move(tmp, SavedDir);
        }
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
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "BabyFlowerChanelu";

        readonly Settings settings = Settings.Load();
        PetDef pet;
        readonly string loadWarning;
        readonly Random rnd = new Random();
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly List<Particle> particles = new List<Particle>();
        readonly float dpi;
        readonly Font particleFont;

        /// <summary>크기에 맞춰 미리 그려 둔 프레임. (프레임 번호, 좌우 뒤집기)</summary>
        readonly Dictionary<(int, bool), Bitmap> frames = new Dictionary<(int, bool), Bitmap>();
        int w, h, headroom, cw, ch;
        float x, footY, vy, target, dir = 1;
        float speed;
        Mode mode = Mode.Idle;
        Anim anim;
        int fi;
        double ft, prev, restUntil, lastInput, zzz;
        Point pressAt, dragOffset;
        bool pressed, dragMoved;

        public PupForm(PetDef pet, string warning)
        {
            this.pet = pet;
            loadWarning = warning;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            Text = "Baby Flower Chanelu";

            using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpi = g.DpiX / 96f;
            particleFont = new Font("Segoe UI Symbol", 15f * dpi, FontStyle.Bold, GraphicsUnit.Pixel);
            speed = 60f * dpi;

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
            if (loadWarning != null)
                BeginInvoke((Action)(() => MessageBox.Show(
                    loadWarning + (pet.Builtin ? "\n대신 샤네루가 나왔어요." : ""), "펫을 불러오지 못했어요",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning)));
        }

        // ---- 크기 ----
        void ApplySize()
        {
            h = (int)Math.Round(settings.Size * dpi);
            w = (int)Math.Round(pet.FW * (float)h / pet.FH);
            headroom = (int)Math.Round(44 * dpi);
            cw = w;
            ch = h + headroom;
            foreach (var f in frames.Values) f.Dispose();
            frames.Clear();
            // 동작에 쓰이는 프레임만 그려 둬요
            foreach (var clip in pet.Clips.Values)
                foreach (var i in clip.Frames)
                {
                    var key = (i, clip.Flip);
                    if (frames.ContainsKey(key)) continue;
                    var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(bmp))
                    {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.CompositingQuality = CompositingQuality.HighQuality;
                        if (clip.Flip) { g.TranslateTransform(w, 0); g.ScaleTransform(-1, 1); }
                        var src = new Rectangle(i % pet.Cols * pet.FW, i / pet.Cols * pet.FH, pet.FW, pet.FH);
                        g.DrawImage(pet.Sheet, new Rectangle(0, 0, w, h), src, GraphicsUnit.Pixel);
                    }
                    frames[key] = bmp;
                }
        }

        /// <summary>다른 펫으로 바꾸기 (메뉴의 펫 불러오기)</summary>
        void SetPet(PetDef p)
        {
            var old = pet;
            pet = p;
            anim = null;
            ApplySize();
            old.Sheet.Dispose();
            UpdateTray();
            StartIdle();
        }

        // ---- 애니메이션 ----
        /// <summary>동작 재생. 펫 파일에 fps가 있으면 그 속도, 없으면 동작별 기본 속도(dur).</summary>
        void Play(string name, double dur, bool loop = false, Action onDone = null)
        {
            if (!pet.Clips.TryGetValue(name, out var clip)) clip = pet.Clips["idle"];
            anim = new Anim { Clip = clip, Dur = clip.Dur ?? dur, Loop = loop, OnDone = onDone };
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
                if (fi >= anim.Clip.Frames.Length)
                {
                    if (anim.Loop) { fi = 0; continue; }
                    fi = anim.Clip.Frames.Length - 1;
                    var done = anim.OnDone;
                    anim.OnDone = null;
                    anim.Dur = double.PositiveInfinity;
                    done?.Invoke();
                    return;
                }
            }
        }

        // ---- 상태 ----
        /// <summary>시트에 없는 동작은 빼고, 있는 동작 중에서 골라요</summary>
        string Pick(string fallback, params string[] names)
        {
            var have = names.Where(pet.Has).ToArray();
            return have.Length > 0 ? have[rnd.Next(have.Length)] : fallback;
        }

        /// <summary>깡충 (없으면 클릭 반응, 그것도 없으면 가만히)</summary>
        string Jump => pet.First("jump", "react", "happy") ?? "idle";

        void StartIdle()
        {
            mode = Mode.Idle;
            restUntil = Now + 2 + rnd.NextDouble() * 5;
            Play(Pick("idle", "idle", "idle", "look", "happy", "sit", "sitBlink"), 0.16, loop: true);
        }

        void StartWalk()
        {
            // 걷는 동작이 없는 펫은 제자리에 있어요
            if (!pet.Has("walkRight")) { StartIdle(); return; }
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
            Play(dir > 0 ? "walkRight" : "walkLeft", 0.1, loop: true);
        }

        void Trick(string name)
        {
            mode = Mode.Busy;
            Play(name, 0.11, onDone: StartIdle);
        }

        void FallAsleep()
        {
            if (mode == Mode.Sleeping || mode == Mode.Dragging || mode == Mode.Falling) return;
            mode = Mode.Busy;
            void SleepLoop()
            {
                mode = Mode.Sleeping;
                Play(pet.Has("sleep") ? "sleep" : "idle", 0.45, loop: true);
            }
            if (pet.Has("sleepStart")) Play("sleepStart", 0.22, onDone: SleepLoop);
            else SleepLoop();
        }

        void WakeUp(Action then)
        {
            if (mode != Mode.Sleeping || !pet.Has("wake")) { then(); return; }
            mode = Mode.Busy;
            Play("wake", 0.15, onDone: then);
        }

        void Pet()
        {
            lastInput = Now;
            Popup("♥", Color.FromArgb(235, 87, 120), 1.2);
            WakeUp(() => Trick(Pick(Jump, "react", "jump", "wave", "beg", "happy")));
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
                    if (footY >= wa.Bottom) { footY = wa.Bottom; vy = 0; Trick(Jump); }
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
                    if (frames.TryGetValue((anim.Clip.Frames[fi], anim.Clip.Flip), out var frame))
                        g.DrawImageUnscaled(frame, 0, ch - h);
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
                Play(pet.First("drag", "react", "jump") ?? "idle", 0.12, loop: true);
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
        readonly ToolStripMenuItem header = new ToolStripMenuItem { Enabled = false };

        void UpdateTray()
        {
            var old = tray.Icon;
            tray.Icon = LoadTrayIcon();
            if (old != null && !ReferenceEquals(old, tray.Icon)) old.Dispose();
            // 트레이 툴팁은 63자까지
            tray.Text = pet.Name.Length > 63 ? pet.Name.Substring(0, 63) : pet.Name;
        }

        /// <summary>pet.json을 골라 펫을 바꾸고, 다음에 켤 때도 그 펫이 나오게 저장해요</summary>
        void ImportPet()
        {
            using (var dlg = new OpenFileDialog { Title = "pet.json 파일을 골라 주세요", Filter = "펫 파일 (pet.json)|*.json|모든 파일|*.*" })
            {
                if (dlg.ShowDialog() != DialogResult.OK) return;
                try
                {
                    var p = PetLoader.FromJson(dlg.FileName);
                    PetLoader.Save(p.SourceDir);
                    SetPet(p);
                }
                catch (Exception e)
                {
                    MessageBox.Show(e.Message, "펫을 불러오지 못했어요", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
        }

        void SetupTray()
        {
            UpdateTray();
            tray.ContextMenuStrip = menu;
            tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) Pet(); };

            var sizeMenu = new ToolStripMenuItem("크기");
            var sleepMenu = new ToolStripMenuItem("안 움직이면 잠들기");
            var startup = new ToolStripMenuItem("윈도우 시작할 때 실행");
            var reset = new ToolStripMenuItem("샤네루로 되돌리기");

            void RefreshChecks()
            {
                foreach (ToolStripMenuItem i in sizeMenu.DropDownItems) i.Checked = (int)i.Tag == settings.Size;
                foreach (ToolStripMenuItem i in sleepMenu.DropDownItems) i.Checked = (int)i.Tag == settings.SleepAfter;
                startup.Checked = IsRunAtStartup();
                header.Text = pet.Name;
                reset.Visible = !pet.Builtin;
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
            reset.Click += (_, __) =>
            {
                try { if (Directory.Exists(PetLoader.SavedDir)) Directory.Delete(PetLoader.SavedDir, true); } catch { }
                SetPet(PetLoader.Chanelu());
            };

            menu.Items.Add(header);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("쓰다듬기", null, (_, __) => Pet());
            menu.Items.Add("재우기", null, (_, __) => FallAsleep());
            menu.Items.Add(sizeMenu);
            menu.Items.Add(sleepMenu);
            menu.Items.Add(startup);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("펫 불러오기…", null, (_, __) => ImportPet());
            menu.Items.Add(reset);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("종료", null, (_, __) => { tray.Visible = false; Application.Exit(); });
            menu.Opening += (_, __) => RefreshChecks();

            RefreshChecks();
            tray.Visible = true;
        }

        Icon LoadTrayIcon()
        {
            if (pet.Builtin)
            {
                try
                {
                    using (var s = typeof(PupForm).Assembly.GetManifestResourceStream("chanelu.ico"))
                        return new Icon(s, SystemInformation.SmallIconSize);
                }
                catch { /* PNG 아이콘을 못 읽는 환경이면 아래처럼 스프라이트 첫 프레임으로 */ }
            }
            // 펫의 가만히 있는 첫 프레임을 32x32 안에 비율 맞춰 그려요
            int first = pet.Clips["idle"].Frames[0];
            var src = new Rectangle(first % pet.Cols * pet.FW, first / pet.Cols * pet.FH, pet.FW, pet.FH);
            float scale = 32f / Math.Max(pet.FW, pet.FH);
            int dw = Math.Max(1, (int)(pet.FW * scale)), dh = Math.Max(1, (int)(pet.FH * scale));
            using (var b = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(b))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(pet.Sheet, new Rectangle((32 - dw) / 2, (32 - dh) / 2, dw, dh), src, GraphicsUnit.Pixel);
                }
                return Icon.FromHandle(b.GetHicon());
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
