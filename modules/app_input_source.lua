--------------------------------------------------------------------------------
-- app_input_source.lua
--
-- 지정한 앱(터미널, 에디터 등)으로 전환(활성화)되면 입력 소스를 영어로
-- 강제합니다. 한글 상태로 터미널에 명령을 치는 사고를 막는 용도입니다.
--
-- 대상 앱은 아래 TARGET_APPS 에 번들 ID 로 등록합니다. 번들 ID 는 콘솔에서
--   hs.application.frontmostApplication():bundleID()
-- 로 확인할 수 있습니다.
--
-- 한글 입력기에서 전환이 가끔 씹히는 문제가 있어, 전환 직후 잠깐 뒤에
-- 반영됐는지 확인하고 안 됐으면 한 번 더 전환합니다 (RETRY_DELAY).
--
-- 이 모듈이 바꾼 전환은 input_source 의 "수동 전환"이 아니므로
-- 알림 모드가 MANUAL 일 때 배지 알림이 뜨지 않습니다 (의도된 동작).
--
-- 설치
--   ~/.hammerspoon/init.lua 에 아래 한 줄 추가
--     require("modules.app_input_source")
--------------------------------------------------------------------------------

local InputSource = require("modules.input_source")

local M = {}

--------------------------------------------------------------------------------
-- 설정
--------------------------------------------------------------------------------

local ENGLISH = InputSource.ENGLISH

-- 활성화 시 영어로 강제할 앱 (번들 ID)
local TARGET_APPS = {
  ["com.googlecode.iterm2"] = true,
  ["com.microsoft.VSCode"]  = true,
}

-- 전환 재확인 대기 시간(초). 한글 입력기 상태에 따라 첫 전환이
-- 반영되지 않는 경우가 있어 이 시간 뒤에 확인하고 재시도합니다.
local RETRY_DELAY = 0.1

M.targetApps = TARGET_APPS

--------------------------------------------------------------------------------
-- 워처
--------------------------------------------------------------------------------

local retryTimers = {}   -- 재시도 타이머 참조 유지 (GC 방지)

local function forceEnglish()
  hs.keycodes.currentSourceID(ENGLISH)
  -- 한글 입력기에서 전환이 가끔 씹히는 문제 보완
  local timer
  timer = hs.timer.doAfter(RETRY_DELAY, function()
    retryTimers[timer] = nil
    if hs.keycodes.currentSourceID() ~= ENGLISH then
      hs.keycodes.currentSourceID(ENGLISH)
    end
  end)
  retryTimers[timer] = true
end

local function onAppEvent(_, event, app)
  if event == hs.application.watcher.activated and app
      and TARGET_APPS[app:bundleID()] then
    forceEnglish()
  end
end

M._onAppEvent = onAppEvent   -- 테스트용

-- 주의: 워처 객체는 반드시 참조를 유지해야 합니다 (input_source 와 동일).
M.watcher = hs.application.watcher.new(onAppEvent)
M.watcher:start()

--------------------------------------------------------------------------------
-- 콘솔용
--------------------------------------------------------------------------------

function M.status()
  local apps = {}
  for id in pairs(TARGET_APPS) do apps[#apps + 1] = id end
  print(string.format("targets=%s current=%s",
    table.concat(apps, ","), tostring(hs.keycodes.currentSourceID())))
end

_G.appInputSource = M   -- Hammerspoon 콘솔에서 접근용
return M
