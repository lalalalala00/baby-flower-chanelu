# Baby Flower Chanelu · 베이비 플라워 샤네루

샤네루가 화면 아래(Dock 위)를 돌아다녀요. VS Code 창 위에도, 다른 앱 위에도 보여요. (맥 전용)

- 클릭: 하트 + 깡충/손 흔들기/두 발 서기
- 드래그: 들어 올렸다 놓으면 툭 떨어져서 깡충
- 저장하면 깡충, 한동안 타이핑이 없으면 잠들고 타이핑하면 깨어나요
- 명령 팔레트: `샤네루 화면에 띄우기/숨기기`, `샤네루 쓰다듬기`, `샤네루 재우기`
- 설정: `chanelu.showOnDesktop`, `chanelu.desktopSize`, `chanelu.speed`, `chanelu.sleepAfterSeconds`
- 탐색기 사이드바의 **샤네루** 패널에도 한 마리 있어요

## 개발
- 데스크톱 프로그램 빌드: `tools/build-desktop.sh` (Swift, 유니버설 바이너리 → `bin/chanelu-desktop`)
- 스프라이트 시트 정리: `tools/clean-sheet.js` (pngjs 필요)
- 패키징: `npx @vscode/vsce package --skip-license`
