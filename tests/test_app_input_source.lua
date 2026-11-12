--------------------------------------------------------------------------------
-- tests/test_app_input_source.lua — 앱 활성화 시 영어 강제 모듈 테스트
--------------------------------------------------------------------------------

local AIS = require("modules.app_input_source")
local IS  = require("modules.input_source")

local KOREAN = "com.apple.inputmethod.Korean.2SetKorean"
local TARGET = "com.googlecode.iterm2"          -- TARGET_APPS 에 있는 앱
local OTHER  = "com.apple.finder"               -- TARGET_APPS 에 없는 앱

-- 워처 핸들러에 넘길 가짜 앱. 실제 앱을 활성화하지 않고 로직만 검증합니다.
local function fakeApp(bundleID)
  return { bundleID = function() return bundleID end }
end

local activated = hs.application.watcher.activated

return {
  {
    name = "대상 앱 활성화 → 영어로 강제",
    fn = function(t)
      local original = hs.keycodes.currentSourceID()
      hs.keycodes.currentSourceID(KOREAN)
      t.waitUntil(function() return hs.keycodes.currentSourceID() == KOREAN end,
        2, "korean set")

      AIS._onAppEvent(nil, activated, fakeApp(TARGET))
      t.waitUntil(function() return hs.keycodes.currentSourceID() == IS.ENGLISH end,
        2, "forced to english")

      hs.keycodes.currentSourceID(original)
      t.sleep(0.3)
    end,
  },
  {
    name = "전환이 씹히면 RETRY_DELAY 뒤 재전환",
    fn = function(t)
      local original = hs.keycodes.currentSourceID()
      hs.keycodes.currentSourceID(KOREAN)
      t.waitUntil(function() return hs.keycodes.currentSourceID() == KOREAN end,
        2, "korean set")

      AIS._onAppEvent(nil, activated, fakeApp(TARGET))
      hs.keycodes.currentSourceID(KOREAN)   -- 첫 전환이 씹힌 상황을 흉내
      t.waitUntil(function() return hs.keycodes.currentSourceID() == IS.ENGLISH end,
        2, "retried to english")

      hs.keycodes.currentSourceID(original)
      t.sleep(0.3)
    end,
  },
  {
    name = "대상이 아닌 앱은 무시",
    fn = function(t)
      local original = hs.keycodes.currentSourceID()
      hs.keycodes.currentSourceID(KOREAN)
      t.waitUntil(function() return hs.keycodes.currentSourceID() == KOREAN end,
        2, "korean set")

      AIS._onAppEvent(nil, activated, fakeApp(OTHER))
      t.sleep(0.3)   -- RETRY_DELAY(0.1) 지난 뒤에도 그대로인지 확인
      t.eq(hs.keycodes.currentSourceID(), KOREAN, "source unchanged")

      hs.keycodes.currentSourceID(original)
      t.sleep(0.3)
    end,
  },
  {
    name = "활성화 외 이벤트(실행 등)는 무시",
    fn = function(t)
      local original = hs.keycodes.currentSourceID()
      hs.keycodes.currentSourceID(KOREAN)
      t.waitUntil(function() return hs.keycodes.currentSourceID() == KOREAN end,
        2, "korean set")

      AIS._onAppEvent(nil, hs.application.watcher.launched, fakeApp(TARGET))
      t.sleep(0.3)
      t.eq(hs.keycodes.currentSourceID(), KOREAN, "source unchanged")

      hs.keycodes.currentSourceID(original)
      t.sleep(0.3)
    end,
  },
  {
    name = "실제 앱 전환 E2E: iTerm2 활성화 시 영어",
    fn = function(t)
      local iterm = hs.application.get(TARGET)
      if not iterm then t.skip("iTerm2 not running") end

      local originalApp    = hs.application.frontmostApplication()
      local originalSource = hs.keycodes.currentSourceID()

      -- iTerm2 가 이미 전면이면 활성화 이벤트가 안 나므로 Finder 를 먼저 전면으로
      local finder = hs.application.get(OTHER)
      if finder then
        finder:activate()
        t.waitUntil(function()
          return hs.application.frontmostApplication():bundleID() == OTHER
        end, 3, "finder frontmost")
      end

      hs.keycodes.currentSourceID(KOREAN)
      t.waitUntil(function() return hs.keycodes.currentSourceID() == KOREAN end,
        2, "korean set")

      iterm:activate()
      t.waitUntil(function() return hs.keycodes.currentSourceID() == IS.ENGLISH end,
        3, "english after real activation")

      -- 원래 상태 복원
      hs.keycodes.currentSourceID(originalSource)
      if originalApp then originalApp:activate() end
      t.sleep(0.5)
    end,
  },
}
