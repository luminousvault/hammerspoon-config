--------------------------------------------------------------------------------
-- audio_events.lua
--
-- hs.audiodevice.watcher 멀티플렉서.
--
-- hs.audiodevice.watcher 콜백은 Hammerspoon 전체에 하나만 등록할 수 있어,
-- 여러 모듈이 각자 setCallback 을 부르면 서로 덮어씁니다. 이 모듈이 콜백을
-- 한 번만 등록하고, 구독한 모듈들에 이벤트를 전달합니다.
--
-- 사용: require("modules.audio_events").subscribe(function(event) ... end)
--   event 는 hs.audiodevice.watcher 가 주는 4글자 문자열
--   ("dev#" = 장치 목록 변경, "dOut" = 기본 출력 변경 등)
--------------------------------------------------------------------------------

local M = { callbacks = {} }

function M.subscribe(fn)
  table.insert(M.callbacks, fn)
end

hs.audiodevice.watcher.setCallback(function(event)
  for _, fn in ipairs(M.callbacks) do
    local ok, err = pcall(fn, event)
    if not ok then
      print("[audio_events] subscriber error: " .. tostring(err))
    end
  end
end)
hs.audiodevice.watcher.start()

return M
