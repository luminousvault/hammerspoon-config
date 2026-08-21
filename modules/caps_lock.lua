--------------------------------------------------------------------------------
-- caps_lock.lua
--
-- CAPS LOCK 잠금 상태가 바뀌면 알림을 표시합니다.
--   켜짐: [⇪] 주황 배지 + "ABC" (2초 — 모르고 지나치면 안 되는 상태)
--   꺼짐: [⇪] 회색 배지 + "abc" (0.6초)
-- 영어 입력 소스일 때만 표시합니다 (한글 입력은 대소문자와 무관).
-- 잠금 상태 추적은 입력 소스와 무관하게 항상 동작합니다.
--
-- 켜고 끄기는 input_source 의 알림 모드를 따릅니다:
--   inputSource.setAlertMode("off") → caps lock 알림도 꺼짐
--   (all/manual 은 모두 표시 — caps 토글은 항상 사용자가 직접 누른 것이므로)
--
-- 제거하려면 이 파일과 tests/test_caps_lock.lua 를 지우고 init.lua 의
-- require("modules.caps_lock") 한 줄을 삭제하면 됩니다.
-- (의존은 caps_lock → input_source 단방향이라 다른 모듈에 영향 없음)
--
-- 설치
--   1) ~/.hammerspoon/init.lua 에 아래 한 줄 추가
--        require("modules.caps_lock")
--   2) 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 에서 Hammerspoon 허용
--      (eventtap 권한 — input_source 와 동일)
--------------------------------------------------------------------------------

local Alert = require("modules.alert")
local InputSource = require("modules.input_source")

local M = {}

local STRINGS = {
  on  = "ABC",
  off = "abc",
}

-- 켜짐 배지 색 (macOS 시스템 주황 계열). 꺼짐은 기본 회색.
local ON_BADGE_COLOR = { red = 1.0, green = 0.42, blue = 0.0, alpha = 0.95 }

-- 켜짐/꺼짐 알림의 박스 너비 통일용. "abc" 가 "ABC" 보다 좁아서
-- 토글 때마다 박스 크기가 달라지는 것을 막습니다. ([⇪] ABC 실측 118px)
local MIN_WIDTH = 120

-- rawFlags 의 caps lock 잠금 비트. getFlags() 에는 capslock 이 없어서
-- (cmd/alt/shift/ctrl/fn 만 제공) raw 플래그 마스크를 씁니다.
local ALPHASHIFT = hs.eventtap.event.rawFlagMasks.alphaShift

-- 마지막으로 인지한 잠금 상태 (같은 상태의 중복 이벤트 무시용)
M.state = hs.hid.capslock.get()

local function showAlert(on)
  Alert.show(on and STRINGS.on or STRINGS.off, {
    badge      = "⇪",
    badgeColor = on and ON_BADGE_COLOR or nil,
    position   = Alert.Position.BOTTOM,
    duration   = on and Alert.Duration.NORMAL or Alert.Duration.SHORT,
    minWidth   = MIN_WIDTH,
  })
end

-- 테스트에서 가짜 이벤트로 호출할 수 있게 M 에 노출합니다.
function M.handle(event)
  local on = (event:rawFlags() & ALPHASHIFT) ~= 0
  if on ~= M.state then
    M.state = on
    if InputSource.alertMode ~= InputSource.AlertMode.OFF
        and hs.keycodes.currentSourceID() == InputSource.ENGLISH then
      showAlert(on)
    end
  end
  return false   -- 반드시 false. 키 이벤트를 통과시켜야 합니다.
end

-- 주의: eventtap 객체는 참조를 유지해야 GC 에 수거되지 않습니다.
M.watcher = hs.eventtap.new(
  { hs.eventtap.event.types.flagsChanged }, M.handle
):start()

--------------------------------------------------------------------------------
-- 콘솔용 (Hammerspoon 콘솔에서 capsLock.xxx() 로 호출)
--------------------------------------------------------------------------------

-- 알림 미리보기 (현재 잠금 상태 기준)
function M.previewAlert()
  showAlert(hs.hid.capslock.get())
end

-- 동작이 멈춘 것 같을 때 확인
function M.status()
  print(string.format("watcher=%s capslock=%s",
    tostring(M.watcher and M.watcher:isEnabled()),
    tostring(hs.hid.capslock.get())))
end

_G.capsLock = M   -- Hammerspoon 콘솔에서 접근용
return M
