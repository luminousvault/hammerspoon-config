--------------------------------------------------------------------------------
-- tests/test_input_source.lua — 한/영 전환 모듈 테스트
--------------------------------------------------------------------------------

local IS    = require("modules.input_source")
local Alert = require("modules.alert")

-- 워처 핸들러에 넘길 가짜 이벤트. 실제 키 이벤트를 만들지 않고
-- 롤 보호 로직만 검증합니다. (synthetic = 모듈이 다시 쏜 이벤트 흉내)
local SYNTH_TAG = 0x48414E
local function fakeEvent(keycode, flags, synthetic)
  return {
    getKeyCode  = function() return keycode end,
    getFlags    = function() return flags end,
    getProperty = function() return synthetic and SYNTH_TAG or 0 end,
  }
end

local RIGHT_CMD = 54

return {
  {
    name = "워처가 켜져 있음",
    fn = function(t)
      t.truthy(IS.flagsWatcher:isEnabled(), "flagsWatcher enabled")
      t.truthy(IS.keyWatcher:isEnabled(), "keyWatcher enabled")
    end,
  },
  {
    name = "toggle 로 전환되고 되돌아옴",
    fn = function(t)
      local before = hs.keycodes.currentSourceID()
      IS.toggle()
      -- 입력 소스 전환은 시스템 상황에 따라 반영이 늦을 수 있어 폴링으로 대기
      t.waitUntil(function() return hs.keycodes.currentSourceID() ~= before end,
        3, "source changed")
      IS.toggle()
      t.waitUntil(function() return hs.keycodes.currentSourceID() == before end,
        3, "source restored")
      t.sleep(1)   -- 알림 소멸 대기
    end,
  },
  {
    name = "MANUAL 모드: 수동 전환만 알림",
    fn = function(t)
      local savedMode = IS.alertMode
      IS.alertMode = IS.AlertMode.MANUAL
      local original = hs.keycodes.currentSourceID()

      IS.toggle()                    -- 수동 전환 → 알림 O
      t.waitUntil(function() return Alert.canvas ~= nil end, 2, "manual alert")
      local manualShown = (Alert.canvas ~= nil)
      t.sleep(1)                     -- 알림 소멸 대기

      hs.keycodes.currentSourceID(original)   -- 외부(시스템) 전환 → 알림 X
      t.sleep(0.3)
      local systemShown = (Alert.canvas ~= nil)

      IS.alertMode = savedMode
      t.truthy(manualShown, "manual toggle shows alert")
      t.eq(systemShown, false, "system change shows no alert")
    end,
  },
  {
    name = "롤 보호: 커맨드를 떼기 전 키 입력은 전환 + 재입력",
    fn = function(t)
      local original = hs.keycodes.currentSourceID()
      local posted = {}
      local savedPost = IS._postKey
      IS._postKey = function(mods, keycode)
        posted[#posted + 1] = { mods = mods, keycode = keycode }
      end

      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = true }))
      local deleted = IS._onKeyDown(fakeEvent(hs.keycodes.map.f, { cmd = true }))

      t.truthy(deleted, "roll key swallowed (shortcut blocked)")
      t.waitUntil(function() return hs.keycodes.currentSourceID() ~= original end,
        3, "source toggled")
      t.waitUntil(function() return #posted == 1 end, 2, "key retyped")
      t.eq(posted[1].keycode, hs.keycodes.map.f, "retyped keycode")

      local toggled = hs.keycodes.currentSourceID()
      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = false }))
      t.sleep(0.3)
      t.eq(hs.keycodes.currentSourceID(), toggled, "no double toggle on release")

      IS._postKey = savedPost
      hs.keycodes.currentSourceID(original)
      t.sleep(1)   -- 알림 소멸 대기
    end,
  },
  {
    name = "롤 보호: 허용 키(,)는 롤 창 안에서도 단축키로 통과",
    fn = function(t)
      local before = hs.keycodes.currentSourceID()

      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = true }))
      local deleted = IS._onKeyDown(fakeEvent(hs.keycodes.map[","], { cmd = true }))
      t.eq(deleted, false, "comma passes through as shortcut")

      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = false }))
      t.sleep(0.3)
      t.eq(hs.keycodes.currentSourceID(), before, "no toggle after shortcut")
    end,
  },
  {
    name = "롤 보호: 롤 창(0.2초) 이후 조합은 단축키로 통과",
    fn = function(t)
      local before = hs.keycodes.currentSourceID()

      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = true }))
      t.sleep(0.3)   -- ROLL_WINDOW 초과 대기
      local deleted = IS._onKeyDown(fakeEvent(hs.keycodes.map.f, { cmd = true }))
      t.eq(deleted, false, "late combo passes through as shortcut")

      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = false }))
      t.sleep(0.3)
      t.eq(hs.keycodes.currentSourceID(), before, "no toggle after shortcut")
    end,
  },
  {
    name = "롤 보호: 모듈이 다시 쏜 합성 이벤트는 통과",
    fn = function(t)
      local before = hs.keycodes.currentSourceID()

      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = true }))
      local deleted =
        IS._onKeyDown(fakeEvent(hs.keycodes.map.f, { cmd = false }, true))
      t.eq(deleted, false, "synthetic event passes through")

      -- 합성 이벤트는 '다른 키'로 카운트되지 않으므로 단독 탭으로 전환됨
      IS._onFlagsChanged(fakeEvent(RIGHT_CMD, { cmd = false }))
      t.waitUntil(function() return hs.keycodes.currentSourceID() ~= before end,
        3, "release still toggles")

      hs.keycodes.currentSourceID(before)
      t.sleep(1)   -- 알림 소멸 대기
    end,
  },
}
