--------------------------------------------------------------------------------
-- tests/test_bluetooth_device.lua — 블루투스 토글 + 자동 재연결 상태 머신 테스트
--
-- 실제 블루투스·스캐너를 건드리지 않도록 가짜 기기를 주입하고
-- audioConnected / connect / spawnScanner 를 가짜로 바꿔 전환만 검증합니다
-- (실행 후 원상복구).
--------------------------------------------------------------------------------

local BT = require("modules.bluetooth_device")

local FAKE_ID = "__test_autoreconnect"

-- 무장 영속화에 쓰는 hs.settings 키 (modules/bluetooth_device.lua 와 동일해야 함)
local SETTINGS_KEY = "bluetooth_device.armed"

-- 가짜 기기·가짜 함수 환경에서 fn 을 돌리고 끝나면 원상복구하는 래퍼
local function withFakes(fn)
  local saved = {
    audioConnected = BT.audioConnected,
    connect        = BT.connect,
    spawnScanner   = BT.spawnScanner,
    settings       = hs.settings.get(SETTINGS_KEY),
  }
  BT.devices[FAKE_ID] = {
    name = "__test device", mac = "00:11:22:33:44:55", autoReconnect = true,
  }
  BT.state[FAKE_ID] = { armed = false }
  BT.spawnScanner = function() end   -- 스캐너 프로세스 없이 감시 상태만 만듦

  local ok, err = pcall(fn)

  BT.stopWatch(FAKE_ID)
  BT.devices[FAKE_ID]  = nil
  BT.state[FAKE_ID]    = nil
  BT.audioConnected    = saved.audioConnected
  BT.connect           = saved.connect
  BT.spawnScanner      = saved.spawnScanner
  hs.settings.set(SETTINGS_KEY, saved.settings or {})

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
    name = "무장 상태로 끊기면 감시 시작, 광고 재등장 시 자동 연결",
    fn = function(t)
      withFakes(function()
        -- 연결 관찰 → 무장, 감시 없음
        BT.audioConnected = function() return true end
        BT.evaluate(FAKE_ID)
        t.eq(BT.state[FAKE_ID].armed, true, "armed while connected")
        t.eq(BT._watches[FAKE_ID], nil, "no watch while connected")

        -- 비자발적 끊김 → 감시 시작 (appear 모드)
        BT.audioConnected = function() return false end
        BT.evaluate(FAKE_ID)
        local w = BT._watches[FAKE_ID]
        t.truthy(w, "watch started after involuntary loss")
        t.eq(w.mode, "appear", "waiting for reappearance")

        -- grace 이후 재등장: 1회로는 부족, 2회째에 연결 1회
        local calls = 0
        BT.connect = function() calls = calls + 1 end
        local base = w.graceUntil + 1
        BT.sighting(FAKE_ID, base)
        t.eq(calls, 0, "single sighting not enough")
        BT.sighting(FAKE_ID, base + 2)
        t.eq(calls, 1, "connect triggered on reappearance")
        t.eq(BT._watches[FAKE_ID], nil, "watch stopped after trigger")
      end)
    end,
  },
  {
    name = "끊긴 직후부터 광고가 보이면 부재를 거치기 전까지 연결하지 않음",
    fn = function(t)
      withFakes(function()
        BT.state[FAKE_ID].armed = true
        BT.audioConnected = function() return false end
        BT.evaluate(FAKE_ID)
        local w = BT._watches[FAKE_ID]
        t.truthy(w, "watch started")

        local calls = 0
        BT.connect = function() calls = calls + 1 end

        -- grace 안에 광고 발견 = 원래 있던 광고 (멀티포인트/뚜껑 열린 케이스)
        BT.sighting(FAKE_ID, w.graceUntil - 1)
        t.eq(w.mode, "absence", "requires absence first")

        -- 계속 보이는 동안은 연결하지 않음
        BT.sighting(FAKE_ID, w.graceUntil + 10)
        BT.sighting(FAKE_ID, w.graceUntil + 12)
        t.eq(calls, 0, "no connect while continuously visible")

        -- 광고가 충분히 오래 사라짐 → 재등장 대기로 전환
        BT.checkAbsence(FAKE_ID, w.lastSeen + 9999)
        t.eq(w.mode, "appear", "absence met, waiting for reappearance")

        -- 재등장 2회 → 연결
        local base = w.lastSeen + 10000
        BT.sighting(FAKE_ID, base)
        BT.sighting(FAKE_ID, base + 2)
        t.eq(calls, 1, "connect after absence then reappearance")
      end)
    end,
  },
  {
    name = "어떤 경로로든 다시 연결되면 감시 종료·무장 유지",
    fn = function(t)
      withFakes(function()
        BT.state[FAKE_ID].armed = true
        BT.audioConnected = function() return false end
        BT.evaluate(FAKE_ID)
        t.truthy(BT._watches[FAKE_ID], "watch running while disconnected")

        -- 기기 주도/단축키 등 어떤 경로로든 연결됨
        BT.audioConnected = function() return true end
        BT.evaluate(FAKE_ID)
        t.eq(BT._watches[FAKE_ID], nil, "watch stopped after connect")
        t.eq(BT.state[FAKE_ID].armed, true, "re-armed")
      end)
    end,
  },
  {
    name = "무장 해제된 기기는 끊겨 있어도 감시하지 않음",
    fn = function(t)
      withFakes(function()
        -- 단축키 해제 직후 상태: armed = false, 연결 없음
        BT.state[FAKE_ID].armed = false
        BT.audioConnected = function() return false end
        BT.evaluate(FAKE_ID)
        t.eq(BT._watches[FAKE_ID], nil, "no watch for disarmed device")
      end)
    end,
  },
}
