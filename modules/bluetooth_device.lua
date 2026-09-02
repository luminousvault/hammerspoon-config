--------------------------------------------------------------------------------
-- bluetooth_device.lua
--
-- 블루투스 기기(이어폰 등) 단축키 연결 토글.
--
-- 기기별 hotkey 로 연결/해제를 토글합니다. blueutil 서브프로세스는 실제
-- 연결/해제 순간에만 실행됩니다.
--
-- 설치
--   1) brew install blueutil
--   2) local_config.lua 에 bluetooth.devices 정의 (local_config.example.lua 참고)
--   3) init.lua 에 require("modules.bluetooth_device")
--------------------------------------------------------------------------------

local Alert = require("modules.alert")

local M = {}

--------------------------------------------------------------------------------
-- 설정
--------------------------------------------------------------------------------

-- 기기 정의(MAC 주소 등 개인정보)는 로컬 전용 파일에서 읽습니다.
local ok, localConfig = pcall(require, "local_config")
if not ok then
  print("[bluetooth_device] failed to load local_config.lua: " .. tostring(localConfig))
  localConfig = {}
end

-- 기기 id → { name, mac, hotkey? }
M.devices = (localConfig.bluetooth or {}).devices or {}

-- 알림에 표시할 문자열. 사용자 언어에 맞게 수정하세요. (로그는 항상 영어)
local STRINGS = {
  connected    = "%s 연결됨",
  connectFail  = "%s 연결 실패",
  disconnected = "%s 연결 해제",
}

local log = hs.logger.new("btDevice", "info")

-- blueutil 경로 (Apple Silicon / Intel Homebrew)
local BLUEUTIL
for _, p in ipairs({ "/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil" }) do
  if hs.fs.attributes(p) then BLUEUTIL = p break end
end

if next(M.devices) and not BLUEUTIL then
  log.e("blueutil not found — run: brew install blueutil")
  return M
end

--------------------------------------------------------------------------------
-- 연결 상태 조회
--------------------------------------------------------------------------------

-- 기기가 오디오 출력 장치로 잡혀 있는지 (in-process, 폴링용 연결 여부 프록시)
function M.audioConnected(name)
  for _, dev in ipairs(hs.audiodevice.allOutputDevices()) do
    if dev:name() == name then return true end
  end
  return false
end

-- blueutil 기준 BT 링크 연결 여부 (동기 ~수십 ms, status() 확인용)
-- 주의: 실제 오디오 사용 가능 상태보다 늦게 바뀌므로 토글 판정에는 쓰지 않음
local function isConnected(def)
  local out = hs.execute(BLUEUTIL .. " --is-connected " .. def.mac)
  return out ~= nil and out:match("^1") ~= nil
end

--------------------------------------------------------------------------------
-- 연결 / 해제 (blueutil 은 몇 초 걸릴 수 있어 hs.task 로 비동기 실행)
--
-- 알림 시점: blueutil 종료 시점은 실제 상태 전환과 어긋납니다 (해제는 실제보다
-- 늦게 종료되고, 연결은 오디오 장치가 쓸 수 있게 되기 전에 종료됨). 그래서
-- 알림은 오디오 장치의 등장/소멸을 짧게 감시하다가 그 순간에 띄웁니다.
--------------------------------------------------------------------------------

local ACTION_POLL    = 0.5   -- 연결/해제 후 실제 전환 감시 주기(초)
local ACTION_TIMEOUT = 12    -- 이 시간 안에 전환이 없으면 포기(초)

local watchers = {}   -- 기기 id → 진행 중인 전환 감시 타이머
local tasks    = {}   -- 기기 id → 실행 중인 blueutil 태스크 (GC 방지용 참조)
local retries  = {}   -- 기기 id → 재시도 대기 타이머

-- 오디오 장치가 원하는 상태(wantConnected)가 되는 순간 onDone() 실행.
-- 시간 내에 안 되면 onTimeout() 실행. 같은 기기의 이전 감시는 대체됩니다.
local function watchTransition(id, def, wantConnected, onDone, onTimeout)
  if watchers[id] then watchers[id]:stop() end
  local waited = 0
  watchers[id] = hs.timer.doEvery(ACTION_POLL, function()
    waited = waited + ACTION_POLL
    if M.audioConnected(def.name) == wantConnected then
      watchers[id]:stop()
      watchers[id] = nil
      onDone()
    elseif waited >= ACTION_TIMEOUT then
      watchers[id]:stop()
      watchers[id] = nil
      if onTimeout then onTimeout() end
    end
  end)
end

-- opts.retried = true 면 재시도분 (내부용. 실패 시 더 재시도하지 않음)
function M.connect(id, opts)
  local def = M.devices[id]
  if not def then return end
  opts = opts or {}

  local function fail(reason)
    log.f("connect %s failed (%s)", id, reason)
    -- 해제 직후에는 기기가 일시적으로 연결을 거부할 수 있어 한 번만 재시도
    if not opts.retried then
      retries[id] = hs.timer.doAfter(2, function()
        log.f("retry connect %s", id)
        M.connect(id, { retried = true })
      end)
      return
    end
    Alert.show(STRINGS.connectFail:format(def.name))
  end

  -- 오디오 장치가 실제로 등장한 순간 = 연결 완료
  watchTransition(id, def, true, function()
    log.f("connect %s ok", id)
    Alert.show(STRINGS.connected:format(def.name))
  end, function()
    fail("timeout")
  end)

  tasks[id] = hs.task.new(BLUEUTIL, function(exitCode)
    -- blueutil 이 명시적으로 실패하면 감시를 접고 바로 실패 처리
    -- (감시가 이미 성공으로 끝났으면 watchers[id] 가 nil 이라 무시됨)
    if exitCode ~= 0 and watchers[id] then
      watchers[id]:stop()
      watchers[id] = nil
      fail("exit " .. exitCode)
    end
  end, { "--connect", def.mac }):start()
end

function M.disconnect(id)
  local def = M.devices[id]
  if not def then return end

  -- 오디오 장치가 실제로 사라진 순간 = 해제 완료 (blueutil 종료보다 빠름)
  watchTransition(id, def, false, function()
    log.f("disconnect %s ok", id)
    Alert.show(STRINGS.disconnected:format(def.name))
  end)

  tasks[id] = hs.task.new(BLUEUTIL, function(exitCode)
    if exitCode ~= 0 and watchers[id] then
      watchers[id]:stop()
      watchers[id] = nil
      log.f("disconnect %s failed (exit %d)", id, exitCode)
    end
  end, { "--disconnect", def.mac }):start()
end

function M.toggle(id)
  local def = M.devices[id]
  if not def then return end

  -- 판정은 오디오 장치 존재 기준: 사용자가 체감하는 상태와 일치하고,
  -- BT 링크 상태(blueutil)보다 전환이 빨라 연속 토글에도 어긋나지 않음
  if M.audioConnected(def.name) then
    M.disconnect(id)
  else
    M.connect(id)
  end
end

--------------------------------------------------------------------------------
-- 단축키 등록
--------------------------------------------------------------------------------

M.hotkeys = {}
for id, def in pairs(M.devices) do
  if def.hotkey then
    M.hotkeys[id] = hs.hotkey.bind(def.hotkey[1], def.hotkey[2],
      function() M.toggle(id) end)
  end
end

--------------------------------------------------------------------------------
-- 콘솔용 함수 (Hammerspoon 콘솔에서 btDevice.xxx() 로 호출)
--------------------------------------------------------------------------------

-- 현재 상태 확인
function M.status()
  for id, def in pairs(M.devices) do
    log.f("  %s: connected=%s", id, tostring(isConnected(def)))
  end
end

_G.btDevice = M   -- Hammerspoon 콘솔에서 접근용
return M
