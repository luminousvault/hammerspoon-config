--------------------------------------------------------------------------------
-- tests/test_input_source.lua — 한/영 전환 모듈 테스트
--------------------------------------------------------------------------------

local IS    = require("modules.input_source")
local Alert = require("modules.alert")

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
}
