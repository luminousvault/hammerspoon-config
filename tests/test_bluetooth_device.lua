--------------------------------------------------------------------------------
-- tests/test_bluetooth_device.lua — 블루투스 재연결 상태 머신 테스트
--
-- 실제 블루투스를 건드리지 않도록 audioConnected/connect 를 가짜로 바꾸고
-- tick() 에 유휴 시간을 주입해 상태 전환만 검증합니다 (실행 후 원상복구).
--------------------------------------------------------------------------------

local BT = require("modules.bluetooth_device")

-- reconnectOnReturn 이 켜진 기기 하나 선택 (테스트 대상)
local function reconnectDevice()
  for id, def in pairs(BT.devices) do
    if def.reconnectOnReturn then return id, def end
  end
end

-- inUse 영속화에 쓰는 hs.settings 키 (modules/bluetooth_device.lua 와 동일해야 함)
local SETTINGS_KEY = "bluetooth_device.inUse"

-- 상태 머신을 가짜 환경에서 돌리고 끝나면 원상복구하는 래퍼
local function withFakes(fn)
  local id = reconnectDevice()
  local saved = {
    audioConnected = BT.audioConnected,
    connect        = BT.connect,
    present        = BT.present,
    inUse          = BT.state[id].inUse,
    settings       = hs.settings.get(SETTINGS_KEY),
  }
  if BT.poll then BT.poll:stop() end   -- 진짜 틱이 끼어들지 않게

  local ok, err = pcall(fn, id)

  BT.audioConnected   = saved.audioConnected
  BT.connect          = saved.connect
  BT.present          = saved.present
  BT.state[id].inUse  = saved.inUse
  hs.settings.set(SETTINGS_KEY, saved.settings or {})
  if BT.poll then BT.poll:start() end

  if not ok then error(err, 0) end
end

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
  {
    name = "쓰던 기기가 끊긴 채 복귀하면 재연결 1회 시도",
    fn = function(t)
      if not reconnectDevice() then t.skip("no reconnectOnReturn device configured") end
      withFakes(function(id)
        -- 자리에서 사용 중 → inUse 기록
        BT.present = true
        BT.state[id].inUse = false
        BT.audioConnected = function() return true end
        BT.tick(0)
        t.eq(BT.state[id].inUse, true, "in-use recorded while present")

        -- 부재 전환
        BT.tick(9999)
        t.eq(BT.present, false, "away after idle threshold")

        -- 끊긴 채 복귀 → 재연결 1회
        local calls = 0
        BT.connect = function() calls = calls + 1 end
        BT.audioConnected = function() return false end
        BT.tick(0)
        t.eq(BT.present, true, "present after return")
        t.eq(calls, 1, "reconnect attempted once")

        -- 같은 세션에서 틱이 반복돼도 추가 시도 없음
        BT.tick(0)
        t.eq(calls, 1, "no retry while present")
      end)
    end,
  },
  {
    name = "안 쓰고 있었으면 복귀해도 시도하지 않음",
    fn = function(t)
      if not reconnectDevice() then t.skip("no reconnectOnReturn device configured") end
      withFakes(function(id)
        BT.present = true
        BT.state[id].inUse = false
        BT.audioConnected = function() return false end
        BT.tick(0)                       -- 사용 기록 없음
        BT.tick(9999)                    -- 부재 전환

        local calls = 0
        BT.connect = function() calls = calls + 1 end
        BT.tick(0)                       -- 복귀
        t.eq(BT.present, true, "present after return")
        t.eq(calls, 0, "no reconnect when device was not in use")
      end)
    end,
  },
  {
    name = "자리에서 미리 끊어둔 기기(충전 등)는 복귀해도 시도하지 않음",
    fn = function(t)
      if not reconnectDevice() then t.skip("no reconnectOnReturn device configured") end
      withFakes(function(id)
        -- 사용 중이다가 자리에서 끊음 (충전 케이스에 넣는 등)
        BT.present = true
        BT.state[id].inUse = false
        BT.audioConnected = function() return true end
        BT.tick(0)
        BT.audioConnected = function() return false end
        BT.tick(0)
        t.eq(BT.state[id].inUse, false, "disconnect while present clears in-use")

        BT.tick(9999)                    -- 부재 전환

        local calls = 0
        BT.connect = function() calls = calls + 1 end
        BT.tick(0)                       -- 복귀
        t.eq(calls, 0, "no reconnect when disconnected before leaving")
      end)
    end,
  },
  {
    name = "사용 기록이 hs.settings 에 보존됨 (리로드 대비)",
    fn = function(t)
      if not reconnectDevice() then t.skip("no reconnectOnReturn device configured") end
      withFakes(function(id)
        -- 자리에서 사용 기록 → settings 에 저장됨 (리로드 시 여기서 복원)
        BT.present = true
        BT.state[id].inUse = false
        BT.audioConnected = function() return true end
        BT.tick(0)
        t.eq((hs.settings.get(SETTINGS_KEY) or {})[id], true,
          "in-use persisted to settings")

        -- 복귀로 세션이 리셋되면 settings 에서도 지워짐
        BT.tick(9999)                    -- 부재 전환
        BT.connect = function() end
        BT.audioConnected = function() return false end
        BT.tick(0)                       -- 복귀 (inUse 리셋)
        t.eq((hs.settings.get(SETTINGS_KEY) or {})[id], nil,
          "in-use cleared from settings after reset")
      end)
    end,
  },
  {
    name = "연결된 채 복귀하면 시도하지 않음 (영상 시청 오탐 등)",
    fn = function(t)
      if not reconnectDevice() then t.skip("no reconnectOnReturn device configured") end
      withFakes(function(id)
        BT.present = true
        BT.state[id].inUse = false
        BT.audioConnected = function() return true end
        BT.tick(0)                       -- 사용 기록
        BT.tick(9999)                    -- 부재 전환 (실은 영상 시청일 수도)

        local calls = 0
        BT.connect = function() calls = calls + 1 end
        BT.tick(0)                       -- 복귀: 여전히 연결돼 있음
        t.eq(calls, 0, "no reconnect when still connected")
        BT.tick(0)                       -- 다음 틱에서 사용 기록 재개
        t.eq(BT.state[id].inUse, true, "in-use re-recorded after return")
      end)
    end,
  },
}
