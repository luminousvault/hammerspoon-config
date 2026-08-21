--------------------------------------------------------------------------------
-- bluetooth_device.lua
--
-- 블루투스 기기(이어폰 등) 단축키 연결 토글 + 자리 복귀 시 자동 재연결.
--
-- 기능
--   1) 단축키 토글 : 기기별 hotkey 로 연결/해제
--   2) 자동 재연결 : 자리를 비웠다 돌아왔을 때, 떠나는 시점에 연결돼 있던
--      기기가 끊겨 있으면 한 번만 재연결 시도(착용한 채 나가서 거리로 끊긴
--      경우). 실패(미착용/전원 꺼짐)는 조용히 무시, 성공 시에만 알림.
--      떠나기 전에 이미 끊어둔 기기(충전, 다른 기기 사용 등)와 자리에 계속
--      있는 동안 끊긴 기기는 건드리지 않음.
--
-- 동작 원리
--   - 10초 타이머가 입력 유휴 시간(hs.host.idleTime)과 기기 연결 여부(오디오
--     출력 장치 존재)를 관찰만 합니다. 둘 다 in-process 조회라 부하는 무시 수준.
--   - 유휴 AWAY_SECS 이상이면 "부재", 이후 입력이 다시 생기면 "복귀"로 판정.
--     잠금/절전 여부와 무관하게 동작합니다 (복귀는 곧 입력 발생이므로).
--   - blueutil 서브프로세스는 실제 연결/해제 순간에만 실행됩니다.
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

-- 기기 id → { name, mac, hotkey?, reconnectOnReturn? }
M.devices = (localConfig.bluetooth or {}).devices or {}

local POLL_INTERVAL = 10    -- 관찰 주기(초). 복귀 후 재연결까지 최대 대기 시간
local AWAY_SECS     = 300   -- 이 시간(초) 이상 입력이 없으면 "부재"로 판정

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
-- 사용 기록 (state.inUse) — 설정 리로드를 넘어 보존
--
-- "자리에 있을 때 마지막으로 관찰된 연결 상태"를 메모리에만 두면, 부재 중에
-- 설정이 리로드되는 순간(설정 수정, 개발 작업 등) 기록이 사라져 복귀 재연결이
-- 무시됩니다. 그래서 변경될 때마다 hs.settings 에 저장하고 로드 시 복원합니다.
--------------------------------------------------------------------------------

local SETTINGS_KEY = "bluetooth_device.inUse"

M.state = {}   -- 기기 id → { inUse = 자리에 있을 때 마지막으로 관찰된 연결 상태 }
local savedInUse = hs.settings.get(SETTINGS_KEY) or {}
for id in pairs(M.devices) do
  M.state[id] = { inUse = savedInUse[id] == true }
end

local function setInUse(id, v)
  if not M.state[id] or M.state[id].inUse == v then return end
  M.state[id].inUse = v
  local toSave = {}
  for did, s in pairs(M.state) do
    if s.inUse then toSave[did] = true end
  end
  hs.settings.set(SETTINGS_KEY, toSave)
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

-- opts.silentFail = true 면 실패 알림 생략 (자동 재연결용)
-- opts.retried    = true 면 재시도분 (내부용. 실패 시 더 재시도하지 않음)
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
        M.connect(id, { silentFail = opts.silentFail, retried = true })
      end)
      return
    end
    if not opts.silentFail then
      Alert.show(STRINGS.connectFail:format(def.name))
    end
  end

  -- 오디오 장치가 실제로 등장한 순간 = 연결 완료
  watchTransition(id, def, true, function()
    log.f("connect %s ok", id)
    setInUse(id, true)
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
-- 자리 복귀 감지 (부재 → 복귀 전환 시에만 재연결 시도)
--------------------------------------------------------------------------------

-- 부재 중에 리로드됐을 수 있으므로 현재 유휴 시간으로 초기화
-- (true 고정이면 리로드 직후 복귀 시 "부재→복귀" 전환을 놓칠 수 있음)
M.present = hs.host.idleTime() < AWAY_SECS

-- 타이머 틱. idle 인자는 테스트 주입용 (생략 시 실제 유휴 시간)
function M.tick(idle)
  idle = idle or hs.host.idleTime()

  if M.present then
    if idle >= AWAY_SECS then
      M.present = false
      log.f("away (idle %ds)", idle)
    else
      -- 자리에 있는 동안 마지막 연결 상태 기록 (관찰만, 블루투스 명령 없음).
      -- 자리에서 끊으면(충전, 다른 기기 사용 등) 기록도 꺼져서 복귀 시 재연결
      -- 대상에서 빠지고, 착용한 채 나가 거리로 끊긴 경우만 대상으로 남습니다.
      for id, def in pairs(M.devices) do
        if def.reconnectOnReturn then
          setInUse(id, M.audioConnected(def.name))
        end
      end
    end
  elseif idle < AWAY_SECS then
    M.present = true
    log.i("returned")
    for id, def in pairs(M.devices) do
      local wasInUse = M.state[id].inUse
      setInUse(id, false)   -- 새 세션 시작 (연결이 살아 있으면 다시 기록됨)
      if def.reconnectOnReturn and wasInUse and not M.audioConnected(def.name) then
        log.f("reconnect %s", id)
        M.connect(id, { silentFail = true })
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 단축키 / 타이머 등록
--------------------------------------------------------------------------------

M.hotkeys = {}
for id, def in pairs(M.devices) do
  if def.hotkey then
    M.hotkeys[id] = hs.hotkey.bind(def.hotkey[1], def.hotkey[2],
      function() M.toggle(id) end)
  end
end

-- 자동 재연결 기기가 하나라도 있을 때만 타이머 생성
for _, def in pairs(M.devices) do
  if def.reconnectOnReturn then
    M.poll = hs.timer.doEvery(POLL_INTERVAL, function() M.tick() end)
    break
  end
end

--------------------------------------------------------------------------------
-- 콘솔용 함수 (Hammerspoon 콘솔에서 btDevice.xxx() 로 호출)
--------------------------------------------------------------------------------

-- 현재 상태 확인
function M.status()
  log.f("present=%s idle=%ds", tostring(M.present), hs.host.idleTime())
  for id, def in pairs(M.devices) do
    log.f("  %s: connected=%s inUse=%s reconnectOnReturn=%s", id,
      tostring(isConnected(def)),
      tostring(M.state[id].inUse),
      tostring(def.reconnectOnReturn or false))
  end
end

_G.btDevice = M   -- Hammerspoon 콘솔에서 접근용
return M
