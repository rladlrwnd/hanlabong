# DragEdit

**글자를 드래그하고 ⌥ Space. 파일을 끌면서 ⇧ ⌘ ⌃.** 그게 전부예요.
macOS 26 이상, Liquid Glass. 모든 변환은 이 컴퓨터 안에서 해요(클라우드 AI는 직접 켰을 때만).

> 소개 페이지: https://rladlrwnd.github.io/hanlabong/ · English summary is at the bottom.

DragEdit는 두 가지 일을 해요.

1. **글자 팝업**(예전 이름 Prism): 어떤 앱에서든 글자를 고르고 ⌥ Space → 바로 아래 유리 팝업에서 규칙(스킬)이나 AI로 고쳐서 그 자리에 다시 넣어요.
2. **파일 휠**: Finder에서 파일을 끌면서 수정키를 누르면 커서 아래에 휠이 떠요. 칸에 놓으면 **원본 옆에 새 파일**로 만들어요. 원본은 절대 고치지 않아요.

---

## 파일 휠

파일을 **끌기 시작한 뒤에** 키를 눌러요. 휠은 키를 떼도 남아 있고, 떠 있는 동안 다른 키를 누르면 그 휠로 바뀌어요. 칸을 옮길 때마다 트랙패드가 톡 울려요.

| 키 | 휠 | 하는 일 |
|---|---|---|
| ⇧ Shift | **변환** | 다른 형식으로 바꾸기 |
| ⌘ Command | **도구** | 편집·회전·용량 줄이기·What is it? 같은 손질 |
| ⌃ Control | **동작** | AirDrop·띄워두기·복사·이동·경로 복사·터미널 (폴더도 돼요) |

키는 설정 › 파일 기능에서 휠마다 ⇧ ⌘ ⌃ ⌥ 중에 바꿀 수 있어요. ⌃는 클릭하기 전에 누르면 오른쪽 클릭이 되니까, 꼭 끌기 시작한 다음에 눌러요.
변환할 게 없는 파일(zip 등)이나 폴더는 어떤 키를 눌러도 동작 휠로 떠요.

### 변환 휠 (⇧)

같은 형식으로 바꾸는 칸은 자동으로 빠져요(예: .md 파일엔 Markdown 칸이 없음).

**사진** (JPG·PNG·HEIC·TIFF·WebP·PSD·AVIF·GIF·RAW)
- **JPG** › 웹용 · 클라이언트 샘플 · 미리보기 (설정에서 고치고 늘릴 수 있는 프리셋)

  | 프리셋 | 하는 일 | 저장 이름 |
  |---|---|---|
  | 웹용 | 긴 변 2048px, sRGB, 위치 삭제, 2MB 이하 | `원본_web.jpg` |
  | 클라이언트 샘플 | 긴 변 4096px, sRGB, "SAMPLE" 워터마크, 위치 삭제 | `원본_sample.jpg` |
  | 미리보기 | 긴 변 2560px, 색 프로필·메타데이터 전부 유지 | `원본_preview.jpg` |
- **PDF** › 그냥 PDF(JPEG는 다시 압축 안 함) · 글자 넣은 PDF(OCR, 검색·복사) · **벡터 PDF · 벡터 SVG**(스캔·사진 찍은 문서를 다시 짓기: 종이를 반듯하게 펴고 그림자를 걷은 뒤, 글자는 글자 인식으로 진짜 글꼴 글자로 — 검색·복사 가능 — 도표의 선·상자·로고는 벡터 모양으로)
- **TXT** › OCR 텍스트 · AI 오타수정(불확실한 곳만 AI가 고치고 검토 창에서 확인 후 저장)
- **형식** › JPG(원본 크기) · PNG · HEIC · AVIF · TIFF · PSD (GIF·BMP는 설정에서 추가)
- 움직이는 **GIF**는 MP4 칸이 하나 더 생겨요.

**PDF**
- Word · 텍스트(TXT·Markdown) · 이미지(JPG·PNG, 300DPI, 여러 쪽이면 폴더 하나에) · PowerPoint(쪽마다 슬라이드) · Excel(줄은 행, 넓은 빈칸은 칸) · EPUB · 기타(HTML·RTF·ODT) · **한글(.hwpx)**
- 글자 없는 스캔 쪽은 자동으로 OCR해서 옮겨요.

**문서** (Word·RTF·ODT·HTML·Markdown·텍스트·EPUB·한글·JSON·CSV·코드…)
- PDF · Word · 텍스트(TXT·Markdown) · HTML · EPUB · 기타(한글·RTF·ODT) — 서로 아무 방향으로.
- 옮기는 건 글·제목·굵게·기울임·목록. 그림·표 모양·각주는 안 옮겨요.

**영상** (MP4·MOV·M4V, ffmpeg가 있으면 AVI·MKV·WebM·WMV·FLV…)
- **MP4** › 1080p · 1080p HEVC(용량 절반) · 720p · 480p
- MOV · MKV · WebM · AVI · WMV · GIF
- **소리** › MP3 · M4A

### 도구 휠 (⌘)

- **사진**: 편집(자르기 비율·회전·반전·밝기·대비·채도) · 회전(90°·-90°·180°) · 반전 · 용량 줄이기(크기 그대로·2MB·500KB). 회전·반전은 원본과 같은 형식으로 저장.
- **영상**: 편집(재생하며 구간 자르기·소리 끄기·품질) · 소리 끄기 · 용량 줄이기
- **PDF**: 글자 넣기(스캔 PDF를 검색되게) · What is it?
- **문서·글**: **What is it?** — 요약이 바로 써지고, Tab을 누르면 심층 분석. 긴 글은 나눠 읽어요. PowerPoint·Excel·한글도 글만 꺼내서 읽어요.

### 동작 휠 (⌃)

AirDrop · **띄워두기**(화면 오른쪽 유리 선반에 올려두고 나중에 끌어 쓰기) · **복사**·**이동**(최근 폴더 4개는 바깥 링에, 그 밖은 폴더 고르기) · 경로 복사 · 터미널에서 열기.
이동은 원본을 옮기는 유일한 기능이에요(덮어쓰지 않음, " (1)"을 붙임).

### 저장과 되돌리기

- 결과는 **원본 옆**에 새 파일. 이름이 겹치면 ` (1)`, ` (2)`. 원본을 고치거나 덮어쓰지 않아요.
- 색 프로필(ICC)과 EXIF는 지우라고 한 경우가 아니면 보존, 16비트는 저장할 때만 바꿔요.
- 5초 넘게 걸리면 휠 자리에 진행 카드(취소 가능)가 뜨고, 끝나면 알림이 와요.
- 메뉴 막대 → "마지막 파일 변환 되돌리기" 또는 설정 › 작업 기록에서 작업별 되돌리기(만든 파일만 휴지통으로).

---

## 글자 팝업

| 키 | 동작 |
|---|---|
| ⌥ Space | 팝업 열기/닫기 |
| 글자 입력 + ⏎ | AI에게 요청 ("…스킬 만들어줘"면 스킬 설계) |
| ⌘1 ~ ⌘9 | 스킬 실행 |
| ↑ ↓ + ⏎ | 목록에서 골라 실행 |
| Tab | 에이전트(AI) 바꾸기 |
| Esc | AI 멈추기 / 닫기 |

- **스킬(규칙)**: 줄바꿈 정리·한 줄로·글머리표·대소문자… AI 없이 즉시. AI에게 "…스킬 만들어줘"라고 하면 미리 만든 블록만 골라 조합하고, 결과를 먼저 보여준 뒤 저장해요.
- **로컬 AI**: Ollama·LM Studio 모델을 자동으로 찾아요. 이 컴퓨터(127.0.0.1)로만 요청해요.
- **클라우드 AI(선택)**: Claude·ChatGPT·Gemini·Groq. 설정에서 직접 켜고 키를 넣어야만 써요(키는 macOS 키체인). 지정한 AI가 꺼져 있으면 다른 AI로 몰래 넘기지 않아요.

## 설정

메뉴 막대 아이콘 → 설정
- **일반**: 언어(한국어·English), 로그인 시 자동 실행, 유리 모양(흐림·틴트·밝기), 파일 기능 켜기/끄기·휠 키
- **에이전트·API 키**: 기본 AI, 기능별 AI(글 팝업·스킬 만들기·OCR 오타수정·What is it?), 모델 메모리 유지 시간
- **파일 휠**: 변환 휠 칸 추가·삭제·순서·2단계 묶음(실제 휠 미리보기)
- **사진 프리셋**: 크기·색·메타데이터·워터마크·저장 형식, 복제해서 새로 만들기. 작가·저작권은 기본으로 비어 있어요 — 여기서 내 이름을 넣으면 사진 정보에 기입되고, 워터마크 글자도 바꿀 수 있어요.
- **작업 기록**: 날짜·개수·실패/취소, Finder에서 보기, 되돌리기

## 필요한 것

- **쓰기만**: macOS 26 이상, Apple silicon.
- **영상 형식 확장(선택)**: AVI·MKV·WebM·WMV·GIF·MP3는 [ffmpeg](https://ffmpeg.org)가 있어야 해요 — `brew install ffmpeg`. 없어도 MP4·MOV·M4A는 돼요.
- **로컬 AI(선택)**: [Ollama](https://ollama.com) 또는 LM Studio.
- **직접 빌드**: Command Line Tools(`xcode-select --install`)면 돼요. Xcode가 있으면 셰이더까지 직접 컴파일해요(없으면 `Prebuilt/`의 컴파일된 셰이더를 써요).

## 설치

### 설치 파일로 (가장 쉬움)

1. [Releases](../../releases)에서 `DragEdit-<버전>.pkg`를 받아서 열어요.
2. **처음 열 때 "확인되지 않은 개발자" 경고가 떠요.** 아직 애플 공증을 받지 않은 앱이라서 그래요. 시스템 설정 › 개인정보 보호 및 보안 맨 아래에서 **그래도 열기**를 누른 뒤 다시 열면 설치 마법사가 떠요.
3. 설치가 끝나면 응용 프로그램에서 DragEdit을 열고, 안내대로 **손쉬운 사용** 권한을 켜요(글자 팝업용). 파일 휠은 권한 없이도 돼요.

### 직접 빌드

```bash
scripts/install.sh      # 최적화 빌드 → /Applications/DragEdit.app 설치 → 실행
scripts/run.sh          # 개발용: 빠른 debug 빌드를 build/에 만들어 실행
scripts/build-app.sh    # 앱 파일만 만들기 (release 기본, debug 가능)
scripts/test.sh         # 자동 테스트 전체 (화면 없이)
scripts/make-pkg.sh     # 설치 마법사(.pkg) 만들기 → build/DragEdit-<버전>.pkg
```

처음 실행하면 "손쉬운 사용" 권한 안내가 떠요. 개발자 인증서(Apple Development)가 있으면 그걸로 서명해서 다시 빌드해도 권한이 유지돼요. 서명할 때 키체인 허용 창이 뜨면 **항상 허용**을 눌러요.
보호 폴더(데스크탑·문서 등)의 파일은 처음 한 번 macOS가 폴더 접근 허용을 물어볼 수 있어요.

## 데이터와 개인정보

- 스킬: `~/Library/Application Support/DragEdit/skills.json` · 파일 휠: `file-wheels.json` · 작업 기록: `file-history.json` (같은 폴더, 사람이 읽을 수 있는 JSON)
- API 키: macOS 키체인(이 맥에서만, 다른 기기로 동기화되지 않음)
- 로그에 글자·파일 내용·파일 이름은 남기지 않아요: `/usr/bin/log stream --predicate 'subsystem == "app.dragedit"'`
- 번들 ID: `app.dragedit.DragEdit`
- **AI에게 넘기는 문서**: 문서는 "자료 칸"으로 감싸서 보내고, 그 안의 명령은 따르지 말라고 AI에게 알려요. 그래도 AI는 속을 수 있으니, 낯선 문서의 요약은 참고용으로 봐주세요. AI는 파일을 지우거나 실행할 권한이 없어요.
- **영상(ffmpeg)**: 파일 앞부분이 진짜 영상일 때만 넘기고, 이 컴퓨터의 파일만 열게(인터넷 주소·재생목록 금지) 막아 두었어요. ffmpeg는 정해진 설치 위치(/opt/homebrew/bin 등)에서만 찾아요.
- **아주 큰 파일**: 문서는 200MB(글 파일 50MB)까지, 압축된 문서 속 내용은 64MB까지만 풀어요. 넘으면 멈추지 않고 거절해요.

## 구조

```
Sources/SkillEngine/        글 블록·스킬 JSON·AI 스킬 설계 검사, 언어(L)
Sources/SkillEngine/File/   파일 블록: 사진(읽기·색·크기·자르기·회전·보정·메타데이터·워터마크·저장), 영상(AVFoundation·ffmpeg),
                            문서(PDF·Word·RTF·ODT·HTML·Markdown·EPUB·한글 읽기/쓰기, OCR, 벡터 재구성, PDF→사진·PPT·엑셀)
Sources/AppCore/            메뉴 막대, 단축키, 비활성 패널, 설정 창, 유리 모양, AI 연결, 키체인
Sources/TextFeature/        글자 팝업
Sources/FileFeature/        드래그 감지, 휠(변환·도구·동작), 편집 창, What is it?, 진행 카드, 검토 창, 작업 기록
Sources/DragEdit/           앱 타깃(위 모듈을 묶기만)
Tests/                      화면 없이 도는 자동 테스트(파일은 코드로 만들어서 확인)
Prebuilt/                   컴파일된 빛줄기 셰이더
Vendor/                     libraries.dev의 BorderBeamKit·ThinkingOrbsKit·BotAvatarsKit (MIT, 각 폴더의 VENDORED.txt)
```

## 라이선스

MIT — [LICENSE](LICENSE). Vendor 폴더의 세 패키지도 MIT(각 폴더의 LICENSE).

## 출처

- 파일 휠의 생각(파일을 끌면서 수정키 → 꽃잎 모양 휠 → 원본 옆에 저장)은 [DragShift](https://github.com/llamaboi55/DragShift) (MIT, © llamaboi55)에서 착안했어요. 코드는 가져오지 않았고 Swift로 새로 만들었어요.
- 변환 범위와 ⇧/⌘/⌃ 세 휠 구성은 [Tangerine](https://tangerineformac.com)을 참고했어요.
- 빛줄기·생각 구슬·봇 아바타: [libraries.dev](https://libraries.dev) (MIT).

---

## English

**Select text and press ⌥ Space. Drag a file and press ⇧ ⌘ ⌃.** DragEdit is a native macOS 26 app (Liquid Glass) that does two things:

- **Text popup** — select text anywhere, press ⌥ Space, fix it with rule-based skills or AI (local Ollama/LM Studio first; cloud Claude/ChatGPT/Gemini/Groq only if you turn it on), and it's pasted back in place.
- **File wheel** — while dragging a file in Finder, press **⇧ Convert**, **⌘ Tools**, or **⌃ Actions**. Drop on a slot and the result is saved **next to the original** (never overwritten).
  - Convert: photos (JPG presets, PNG/HEIC/AVIF/TIFF/PSD, PDF, OCR text, vector SVG/PDF tracing), PDF (Word, text/Markdown, JPG/PNG pages at 300 DPI, PowerPoint, Excel, EPUB, HTML/RTF/ODT, Hangul .hwpx), documents in any direction, video (MP4 presets, MOV/MKV/WebM/AVI/WMV/GIF, MP3/M4A — non-Apple formats need `brew install ffmpeg`).
  - Tools: photo editor (crop/rotate/flip/adjust), rotate, flip, shrink; video trim/mute/shrink; searchable PDF; **What is it?** AI summary (Tab for a deep dive).
  - Actions: AirDrop, Float shelf, copy/move to recent folders, copy path, open in Terminal — works on folders too.
- Everything runs on your Mac. The UI is available in Korean and English (Settings › General › Language).

Download the `.pkg` from Releases (it is not notarized yet: on first open use System Settings › Privacy & Security › Open Anyway), or build with `scripts/install.sh` (Command Line Tools are enough). Inspired by [DragShift](https://github.com/llamaboi55/DragShift) (MIT) and [Tangerine](https://tangerineformac.com).
