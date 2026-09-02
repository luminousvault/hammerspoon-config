--------------------------------------------------------------------------------
-- tests/test_bluetooth_device.lua — 블루투스 기기 단축키 토글 테스트
--
-- 실제 블루투스를 건드리지 않고 설정·바인딩만 검증합니다.
--------------------------------------------------------------------------------

local BT = require("modules.bluetooth_device")

return {
  {
    name = "설정된 기기의 단축키가 바인딩됨",
    fn = function(t)
      local bound = false
      for id, def in pairs(BT.devices) do
        if def.hotkey then
          t.truthy(BT.hotkeys[id], "hotkey bound for " .. id)
          bound = true
        end
      end
      if not bound then t.skip("no bluetooth device with hotkey configured") end
    end,
  },
}
