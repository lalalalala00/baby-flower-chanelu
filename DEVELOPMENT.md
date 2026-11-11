# 개발 메모

- 데스크톱 프로그램 빌드: `tools/build-desktop.sh` (Swift, 유니버설 바이너리 → `bin/chanelu-desktop`)
- 스프라이트 시트 정리: `tools/clean-sheet.js <원본시트.png> <출력.png>` (pngjs 필요)
- F5: 확장 개발 호스트에서 실행
- 패키징: `npm run package` (README 이미지 주소를 raw.githubusercontent.com으로 바꿔서 묶어요)

## VS Code 없이 쓰는 데스크톱 앱
- 맥: `tools/build-desktop.sh && tools/build-app.sh` → `dist/Chanelu-mac.zip` (Chanelu.app)
  - 인자 없이 실행되면 혼자 실행 모드: 메뉴 막대 아이콘, 키보드·마우스 기준으로 잠들기
  - 테스트할 때 VS Code 샤네루와 겹치지 않게: `CHANELU_SOCKET=/tmp/test.sock dist/Chanelu.app/Contents/MacOS/Chanelu`
- 윈도우: `windows/` (C#, .NET Framework 4.8) — GitHub Actions가 빌드
- 아이콘: `node tools/make-ico.js` → `windows/chanelu.ico`
- 릴리스를 만들면 `.github/workflows/desktop.yml`이 맥 zip과 윈도우 exe를 릴리스에 붙여요

## 다른 펫 띄우기 (pet.json)
- 형식: [docs/pet-format.md](docs/pet-format.md)
- 맥에서 테스트: `CHANELU_SOCKET=/tmp/test.sock CHANELU_PET=<펫 폴더> dist/Chanelu.app/Contents/MacOS/Chanelu`
- 윈도우에서 테스트: `Chanelu.exe <펫 폴더>\pet.json`
