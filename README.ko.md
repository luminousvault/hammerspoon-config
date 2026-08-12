# Hammerspoon 설정

[![License](https://img.shields.io/github/license/luminousvault/hammerspoon-config)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)](https://www.hammerspoon.org/)
[![Lua](https://img.shields.io/badge/Lua-5.4-2C2D72?logo=lua&logoColor=white)](https://www.lua.org/)

[English](README.md) | **한국어**

macOS 자동화 도구 [Hammerspoon](https://www.hammerspoon.org/) 개인 설정.

## 기능

| 모듈 | 설명 |
|------|------|
| [`modules/input_source.lua`](modules/input_source.lua) | **오른쪽 커맨드 키 단독 탭으로 한/영 전환.** 다른 키와 조합하면 일반 커맨드 키로 동작. 전환 시 포커스된 화면 하단에 `[한] 두벌식` / `[A] ABC` 알림 표시 (모드: all / manual / off) |
| [`modules/audio_by_location.lua`](modules/audio_by_location.lua) | **Wi-Fi SSID 기준 오디오 자동 전환.** `local_config.lua` 에 장소를 자유롭게 정의하고 장소별 정책 지정: 고정값 또는 기억·복원(`remember`), 블루투스 이어폰 등 개인 기기를 건드리지 않는 스피커 한정 적용(`speakerOnly`), 절전 복귀 시 재적용(`enforceOnWake`) |
| [`modules/caps_lock.lua`](modules/caps_lock.lua) | **CAPS LOCK 토글 알림.** 켜지면 `[⇪] ABC` (주황 배지, 2초), 꺼지면 `[⇪] abc` (회색, 0.6초). 켜고 끄기는 input_source 의 알림 모드를 따름 (`off` 면 숨김) |
| [`modules/alert.lua`](modules/alert.lua) | **공통 알림 UI.** `hs.alert` 대체. 위치(TOP/CENTER/BOTTOM)·시간(SHORT/NORMAL/LONG) 지정, 배지(글자 또는 아이콘) 지원 |

## 설치

```bash
git clone <repo-url> ~/.hammerspoon
cd ~/.hammerspoon
cp local_config.example.lua local_config.lua   # 장소와 SSID 정의
```

1. Hammerspoon 설치: `brew install --cask hammerspoon`
2. `local_config.lua` 에 장소(SSID + 오디오 정책)를 정의
3. Hammerspoon 실행 후 권한 허용:
   - **손쉬운 사용** (시스템 설정 → 개인정보 보호 및 보안): 키 이벤트 감지(`eventtap`)에 필요
   - **위치 서비스**: macOS Sonoma 이후 SSID 조회에 필요 (없으면 SSID 가 항상 nil)

## 사용법

- 설정 리로드: `⌘⌥⌃R` (또는 메뉴바 아이콘 → Reload Config)
- 터미널 연동(`hs` CLI): `require("hs.ipc")` 로 활성화되어 있음

### 콘솔 명령

Hammerspoon 콘솔 또는 터미널 `hs -c "..."` 에서:

```lua
inputSource.status()             -- 한/영 전환 워처 상태 확인
inputSource.setAlertMode("all")  -- 알림 모드: "all" / "manual" / "off"
inputSource.previewAlert()       -- 알림 디자인 미리보기

audioLoc.status()                -- SSID·장소·출력기기·음소거 상태 확인
audioLoc.reapply()               -- 현재 장소 정책 즉시 재적용
audioLoc.pin()                   -- 지금 상태를 현재 장소 값으로 저장 (기억 장소만)
audioLoc.reset()                 -- 기억값 초기화

customAlert.show("메시지")       -- 공통 알림 직접 호출
```

## 테스트

```bash
./tests/run.sh
```

통합 테스트는 실행 중인 Hammerspoon 런타임 안에서 돕니다 — 화면에 알림이 뜨고 오디오 상태를 잠깐 건드렸다가 복원하므로, 회의 중이 아닐 때 돌리세요. 현재 환경과 전제 조건이 안 맞는 테스트(미등록 SSID, 블루투스 기기 없음 등)는 SKIP 으로 표시됩니다.

새 테스트는 `tests/test_<기능>.lua` 파일을 만들어 `{ { name = ..., fn = function(t) ... end }, ... }` 를 반환하기만 하면 됩니다 — 파일이 자동 발견되므로 러너 수정이 필요 없습니다. `t` 로 쓸 수 있는 헬퍼: `sleep`, `waitUntil`, `eq`, `truthy`, `skip`.

## 구조

```
~/.hammerspoon/
├── init.lua                    # 진입점: 모듈 로드, 리로드 단축키
├── local_config.lua            # 머신 전용 설정 (SSID 등, 커밋 안 됨)
├── local_config.example.lua    # local_config 템플릿
└── modules/
    ├── alert.lua               # 공통 알림 UI
    ├── input_source.lua        # 한/영 전환 + 전환 알림
    └── audio_by_location.lua   # 장소별 오디오 자동 전환
```
