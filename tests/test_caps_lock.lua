--------------------------------------------------------------------------------
-- tests/test_caps_lock.lua — CAPS LOCK 알림 모듈 테스트
--
-- 실제 caps lock 을 토글하는 대신 rawFlags() 만 흉내 낸 가짜 이벤트로
-- 핸들러를 직접 호출합니다 (실행 후 모듈 상태 원상복구).
--------------------------------------------------------------------------------

local CL = require("modules.caps_lock")

local ALPHASHIFT = hs.eventtap.event.rawFlagMasks.alphaShift

local function fakeEvent(on)
  return { rawFlags = function() return on and ALPHASHIFT or 0 end }
end

return {
  {
    name = "워처가 켜져 있음",
    fn = function(t)
      t.truthy(CL.watcher and CL.watcher:isEnabled(), "caps lock watcher enabled")
    end,
  },
  {
    name = "잠금 상태 변경 감지 (중복 이벤트 무시)",
    fn = function(t)
      local saved = CL.state

      CL.state = false
      CL.handle(fakeEvent(true))           -- OFF → ON: 알림 표시
      t.eq(CL.state, true, "state updated to on")
      CL.handle(fakeEvent(true))           -- 같은 상태 반복 → 무시
      t.eq(CL.state, true, "duplicate event ignored")
      t.sleep(1)                           -- 알림 소멸 대기

      CL.handle(fakeEvent(false))          -- ON → OFF: 알림 표시
      t.eq(CL.state, false, "state updated to off")
      t.sleep(1)

      CL.state = saved                     -- 원상복구
    end,
  },
  {
    name = "inputSource 알림 모드 off 면 알림 없이 상태만 갱신",
    fn = function(t)
      local IS = require("modules.input_source")
      local savedMode, savedState = IS.alertMode, CL.state

      IS.alertMode = IS.AlertMode.OFF
      CL.state = false
      CL.handle(fakeEvent(true))           -- 알림은 억제, 상태는 추적
      t.eq(CL.state, true, "state still tracked while alerts off")

      IS.alertMode, CL.state = savedMode, savedState
    end,
  },
}
