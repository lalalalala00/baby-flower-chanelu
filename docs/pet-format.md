# 펫 파일 형식 (pet.json, version 1)

샤네루 데스크톱 앱(맥 `Chanelu.app`, 윈도우 `Chanelu.exe`)은 기본 샤네루 대신 다른 펫을 띄울 수 있어요.
펫 하나는 **pet.json + 스프라이트 시트 이미지** 두 파일이에요.

```text
MyPet/
├── Chanelu.app  (또는 Chanelu.exe)
└── PetData/
    ├── pet.json
    └── spritesheet.png
```

## 예시

```json
{
  "version": 1,
  "name": "우리 콩이",
  "sprite": "spritesheet.png",
  "frameWidth": 192,
  "frameHeight": 208,
  "walkFacing": "right",
  "animations": {
    "idle":  { "frames": [0, 1, 2, 3], "fps": 4 },
    "walk":  { "frames": [8, 9, 10, 11], "fps": 8 },
    "sleep": { "frames": [16, 17, 18], "fps": 3 },
    "jump":  { "frames": [24, 25, 26, 27], "fps": 10 },
    "react": { "frames": [32, 33, 34], "fps": 8 }
  }
}
```

## 필드

| 필드 | 필수 | 설명 |
|---|---|---|
| `version` | | `1`. 앱이 아는 버전보다 크면 "앱을 업데이트해 주세요"라고 알려요. |
| `name` | | 메뉴와 툴팁에 보이는 이름. 없으면 "내 펫". |
| `sprite` | ✓ | 시트 이미지 파일 이름 (PNG 권장, 투명 배경). pet.json과 같은 폴더 기준이고, `..`나 절대 경로는 쓸 수 없어요. |
| `frameWidth`, `frameHeight` | ✓ | 프레임 한 칸의 픽셀 크기 (1–4096). |
| `columns` | | 한 줄에 프레임이 몇 칸인지. 없으면 `이미지 너비 / frameWidth`. |
| `walkFacing` | | `walk` 프레임이 바라보는 방향, `"right"`(기본) 또는 `"left"`. 반대 방향은 좌우를 뒤집어 그려요. |
| `animations` | | 동작 이름 → `{ "frames": [...], "fps": 숫자 }`. 아래 표 참고. |

**프레임 번호**는 시트를 왼쪽 위부터 오른쪽으로, 줄이 끝나면 다음 줄로 세요: `번호 = 행 × columns + 열` (0부터).
시트 밖을 가리키는 번호는 무시해요.

시트는 **칸이 고르게 나뉜 격자**여야 해요. 프레임마다 위치나 크기를 따로 맞추는 기능은 없으니,
웹 제작기에서 프레임을 정리한 다음 고른 격자로 다시 그려서 내보내야 해요.

동작마다 `fps`(초당 프레임, 최대 60)를 쓸 수 있고, 없으면 동작별 기본 속도를 써요.
반복 여부는 동작마다 정해져 있어서 `loop` 값은 읽지 않아요 (적어 둬도 괜찮아요).
`"flip": true`를 넣으면 그 동작을 좌우로 뒤집어 그려요.

## 동작

모든 동작은 선택이에요. 없는 동작은 오른쪽 열의 다른 동작으로 대신해요.

| 이름 | 언제 | 반복 | 기본 속도 | 없으면 |
|---|---|---|---|---|
| `idle` | 가만히 있을 때 | 반복 | 6.25 fps | 아무 동작의 첫 프레임 하나 |
| `look`, `happy`, `sit`, `sitBlink` | 가만히 있을 때 가끔 섞여요 | 반복 | 6.25 fps | `idle`만 |
| `walk` | 화면 아래를 걸을 때 (`walkFacing` 방향) | 반복 | 10 fps | 걷지 않고 제자리 |
| `walkRight`, `walkLeft` | 방향별로 따로 그린 걷기 (`walk`보다 우선) | 반복 | 10 fps | `walk`를 뒤집어서 |
| `jump` | 들었다 놓았을 때, 저장했을 때 | 한 번 | 9 fps | `react` → `happy` → `idle` |
| `react` | 클릭했을 때 (`jump`, `wave`, `beg`, `happy`와 섞여서 무작위) | 한 번 | 9 fps | `jump` 등 |
| `wave`, `beg` | 클릭 반응. VS Code에서 AI가 확인을 기다릴 때 (`wave` → `beg`) | 한 번 | 9 fps | `react` / `jump` |
| `drag` | 마우스로 들고 있을 때 | 반복 | 8.3 fps | `react` → `jump` → `idle` |
| `sleepStart` | 잠드는 중 (눕기) | 한 번 | 4.5 fps | 바로 `sleep` |
| `sleep` | 자는 중 | 반복 | 2.2 fps | `idle` |
| `wake` | 깨어날 때 | 한 번 | 6.7 fps | `sleepStart`를 거꾸로, 그것도 없으면 바로 깸 |

## 앱이 펫을 찾는 순서

**맥 (Chanelu.app 혼자 실행)**
1. 환경 변수 `CHANELU_PET` (pet.json 또는 그 폴더 경로, 테스트용)
2. 앱 옆의 `PetData/pet.json`, 없으면 `pet.json`
   (인터넷에서 받은 앱을 macOS가 임시 위치로 옮겨 실행해도 원래 위치를 찾아요)
3. 메뉴 막대 → **펫 불러오기…** 로 저장해 둔 펫 (`~/Library/Application Support/Chanelu/Pet/`)
4. 기본 샤네루

**윈도우 (Chanelu.exe)**
1. 실행 인자 (pet.json 경로, pet.json을 exe에 끌어다 놓아도 돼요)
2. exe 옆의 `PetData\pet.json`, 없으면 `pet.json`
3. 트레이 메뉴 → **펫 불러오기…** 로 저장해 둔 펫 (`%APPDATA%\Chanelu\Pet\`)
4. 기본 샤네루

펫 파일을 읽지 못하면 그 이유를 창으로 알려 주고 다음 순서로 넘어가요.
메뉴의 **샤네루로 되돌리기**는 저장해 둔 펫을 지워요.

**VS Code 확장**은 지금처럼 샤네루 시트를 넘겨요. 첫 인자로 `.json` 경로를 주면 그 펫을 띄워요.
