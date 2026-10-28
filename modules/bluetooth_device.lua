--------------------------------------------------------------------------------
-- bluetooth_device.lua
--
-- 블루투스 기기(이어폰 등) 단축키 연결 토글 + BLE 근접 자동 재연결.
--
-- 기능
--   1) 단축키 토글 : 기기별 hotkey 로 연결/해제
--   2) 자동 재연결 : (autoReconnect = true 기기) 착용한 채 자리를 비워 거리로
--      끊겼다가 돌아오면 자동 연결. 기기의 BLE 광고가 "사라졌다 재등장"하는
--      전이를 근접 신호로 사용.
--
-- 자동 재연결 동작 원리
--   - 연결되면 "무장(armed)". 단축키로 끊으면 무장해제(자동화 전체 중단).
--     그 외의 끊김(거리, 케이스 등)이면 helpers/ble-adv-watch 스캐너를 띄워
--     기기 광고를 감시.
--   - 광고는 제조사 데이터에 실린 기기 Classic MAC 으로 식별 (로컬 이름은
--     충전 케이스도 같은 값을 광고하므로 쓰지 않음. PoC 실측 2026-10)
--   - 끊긴 직후부터 광고가 계속 보이면(멀티포인트로 폰에 연결, 뚜껑 열린
--     케이스 등) "재등장"이 아니므로 연결하지 않고, 광고가 끊겼다가 다시
--     나타날 때만 연결. 케이스에서 꺼낼 때의 재연결은 기기가 스스로 함.
--   - 스캐너는 "무장 상태로 끊겨 있는 동안"만 실행. blueutil 서브프로세스는
--     실제 연결/해제 순간에만 실행.
--
-- 설치
--   1) brew install blueutil
--   2) (자동 재연결 사용 시) swiftc -O -o helpers/ble-adv-watch helpers/ble-adv-watch.swift
--   3) local_config.lua 에 bluetooth.devices 정의 (local_config.example.lua 참고)
--   4) init.lua 에 require("modules.bluetooth_device")
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

-- 기기 id → { name, mac, hotkey?, autoReconnect? }
M.devices = (localConfig.bluetooth or {}).devices or {}

-- 자동 재연결 파라미터
local RSSI_MIN       = -70   -- 이보다 약한 광고는 무시 (책상 거리 실측 -40 안팎)
local SIGHT_GRACE    = 30    -- 끊긴 뒤 이 시간(초) 안에 광고가 보이면 "원래 있던 것"
local ABSENCE_SECS   = 60    -- 광고가 이 시간(초) 이상 안 보여야 "부재"로 인정
local ABSENCE_POLL   = 10    -- 부재 판정 주기(초)
local TRIGGER_COUNT  = 2     -- 재등장 판정에 필요한 광고 수신 횟수
local TRIGGER_WINDOW = 15    -- 그 횟수를 세는 시간 창(초)
local HELPER_RETRY   = 60    -- 스캐너 비정상 종료 시 재시작 대기(초)

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

-- BLE 스캐너 헬퍼 (자동 재연결용. 없으면 자동 재연결만 비활성화)
local HELPER = hs.configdir .. "/helpers/ble-adv-watch"
local autoIds = {}   -- autoReconnect = true 인 기기 id 목록
for id, def in pairs(M.devices) do
  if def.autoReconnect then table.insert(autoIds, id) end
end
if #autoIds > 0 and not hs.fs.attributes(HELPER) then
  log.e("ble-adv-watch not found — run: swiftc -O -o helpers/ble-adv-watch helpers/ble-adv-watch.swift")
  autoIds = {}
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
-- 무장 상태 (state.armed) — 설정 리로드를 넘어 보존
--
-- "연결돼 있(었)으므로 끊기면 복귀를 감시할 기기"가 무장 상태입니다.
-- 메모리에만 두면 부재 중 설정 리로드 시 기록이 사라져 복귀 재연결이
-- 무시되므로, 변경될 때마다 hs.settings 에 저장하고 로드 시 복원합니다.
--------------------------------------------------------------------------------

local SETTINGS_KEY = "bluetooth_device.armed"

M.state = {}   -- 기기 id → { armed }
local savedArmed = hs.settings.get(SETTINGS_KEY) or {}
for id in pairs(M.devices) do
  M.state[id] = { armed = savedArmed[id] == true }
end

local function setArmed(id, v)
  if not M.state[id] or M.state[id].armed == v then return end
  M.state[id].armed = v
  local toSave = {}
  for did, s in pairs(M.state) do
    if s.armed then toSave[did] = true end
  end
  hs.settings.set(SETTINGS_KEY, toSave)
end

-- 광고 감시 (정의는 아래 "자동 재연결" 섹션. connect/disconnect 가 참조)
local startWatch, stopWatch

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
-- opts.auto    = true 면 자동 재연결발 호출 (실패를 조용히 무시하고 감시 재개)
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
        M.connect(id, { retried = true, auto = opts.auto })
      end)
      return
    end
    if opts.auto then
      -- 자동 연결 실패는 알림 없이, 광고가 다시 사라졌다 나타날 때 재시도
      -- (근처에 있지만 연결을 거부하는 기기에 연타하지 않도록 부재를 요구)
      if M.state[id] and M.state[id].armed then
        startWatch(id, { requireAbsence = true })
      end
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

  -- 단축키(의도적) 해제 = 무장해제. 광고 감시를 멈추고 자동 재연결도 중단.
  -- 다음에 어떤 경로로든 다시 연결되는 순간 재무장됩니다.
  setArmed(id, false)
  stopWatch(id)

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
-- 자동 재연결: BLE 광고 감시
--
-- 무장 상태로 끊긴 기기마다 ble-adv-watch 를 하나 띄워 광고 수신을 감시.
--   mode "appear"  : 광고 재등장을 기다리는 중 (재등장 = 복귀 → 연결)
--   mode "absence" : 광고가 이미 보여서, 먼저 사라지기를 기다리는 중
--     (끊긴 직후부터 광고가 보이면 멀티포인트로 폰에 연결됐거나 뚜껑 열린
--      케이스에 든 경우 등 "자리를 비운 것"이 아니므로 연결하지 않음)
--------------------------------------------------------------------------------

-- 테스트에서 가짜로 바꿀 수 있도록, 감시 로직의 접점(sighting / checkAbsence /
-- spawnScanner / evaluate / connect)은 M 테이블 경유로 호출합니다.

local watches       = {}   -- 기기 id → { task, mode, graceUntil, lastSeen, recent, absenceTimer }
local watchRestarts = {}   -- 기기 id → 스캐너 비정상 종료 후 재시작 타이머
M._watches = watches       -- 테스트 검사용 (외부 사용 금지)

stopWatch = function(id)
  local w = watches[id]
  if watchRestarts[id] then
    watchRestarts[id]:stop()
    watchRestarts[id] = nil
  end
  if not w then return end
  watches[id] = nil
  if w.absenceTimer then w.absenceTimer:stop() end
  if w.task and w.task:isRunning() then w.task:terminate() end
end
M.stopWatch = stopWatch

local function enterAbsenceMode(id, w)
  w.mode = "absence"
  w.lastSeen = hs.timer.secondsSinceEpoch()
  w.recent = {}
  if w.absenceTimer then w.absenceTimer:stop() end
  w.absenceTimer = hs.timer.doEvery(ABSENCE_POLL, function()
    M.checkAbsence(id, hs.timer.secondsSinceEpoch())
  end)
end

-- 부재 판정: absence 모드에서 광고가 ABSENCE_SECS 이상 안 보이면 appear 로 전환
function M.checkAbsence(id, now)
  local w = watches[id]
  if not w or w.mode ~= "absence" then return end
  if now - w.lastSeen < ABSENCE_SECS then return end
  if w.absenceTimer then
    w.absenceTimer:stop()
    w.absenceTimer = nil
  end
  w.mode = "appear"
  w.graceUntil = nil
  log.f("watch %s: advertisement gone, waiting for reappearance", id)
end

-- 광고 1회 수신 처리
function M.sighting(id, now)
  local w = watches[id]
  if not w then return end

  if w.mode == "absence" then
    w.lastSeen = now
    return
  end

  -- 끊긴 직후(grace 안)에 광고가 보이면 "원래 있던 것" → 부재부터 요구
  if w.graceUntil and now < w.graceUntil then
    log.f("watch %s: advertisement already present, requiring absence first", id)
    enterAbsenceMode(id, w)
    return
  end

  -- 재등장 판정: 짧은 창 안에 여러 번 보여야 인정 (경계 거리 깜빡임 방지)
  local kept = {}
  for _, ts in ipairs(w.recent) do
    if now - ts <= TRIGGER_WINDOW then table.insert(kept, ts) end
  end
  table.insert(kept, now)
  w.recent = kept
  if #w.recent >= TRIGGER_COUNT then
    log.f("watch %s: advertisement reappeared, connecting", id)
    stopWatch(id)
    M.connect(id, { auto = true })
  end
end

-- 스캐너 프로세스 기동. 수신한 광고를 M.sighting 으로 넘깁니다.
function M.spawnScanner(id, def, w)
  w.task = hs.task.new(HELPER, function(exitCode, _, stdErr)
    -- stopWatch 의 terminate 면 watches[id] 가 이미 비워져 있어 무시됨.
    -- 그 외(블루투스 꺼짐, 크래시 등)는 잠시 후 재시작.
    if watches[id] ~= w then return end
    stopWatch(id)
    log.ef("watch %s: scanner exited (%s) %s", id, tostring(exitCode),
           (stdErr or ""):gsub("%s+$", ""))
    watchRestarts[id] = hs.timer.doAfter(HELPER_RETRY, function()
      watchRestarts[id] = nil
      if M.state[id].armed and not M.audioConnected(def.name) then
        startWatch(id)
      end
    end)
  end, function(_, stdOut)
    if watches[id] ~= w then return false end
    local now = hs.timer.secondsSinceEpoch()
    for _ in (stdOut or ""):gmatch("[^\n]+") do
      M.sighting(id, now)
    end
    return true
  end, { def.mac, "--rssi", tostring(RSSI_MIN) })
  w.task:start()
end

-- opts.requireAbsence = true 면 "appear" 대신 부재 대기부터 시작
startWatch = function(id, opts)
  opts = opts or {}
  local def = M.devices[id]
  if not def or not def.autoReconnect or watches[id] then return end

  local w = {
    mode = "appear",
    recent = {},
    graceUntil = hs.timer.secondsSinceEpoch() + SIGHT_GRACE,
  }
  watches[id] = w
  M.spawnScanner(id, def, w)

  if opts.requireAbsence then enterAbsenceMode(id, w) end
  log.f("watch %s: scanning (%s)", id, w.mode)
end

-- 연결/해제 이벤트에 따른 무장·감시 전환.
-- 오디오 장치 목록 변경(dev#)마다 재평가하며, 모든 전이가 여기로 수렴합니다:
--   미연결→연결 전이(어떤 경로든) → 무장 + 감시 종료
--   무장 상태로 끊김(비자발적)    → 감시 시작 (단축키 해제는 disconnect 가 먼저
--                                  무장해제하므로 여기 해당 없음)
-- 무장을 "연결돼 있음"이 아니라 연결 전이에만 거는 이유: 해제 과정에서 입력/
-- 출력 장치가 따로 사라지며 dev# 가 여러 번 오는데, 그 중간(출력이 아직 남은)
-- 시점에 "연결됨"으로 재무장해 버리면 단축키 해제가 무효가 됩니다.
local lastConnected = {}   -- 기기 id → 직전 평가의 연결 여부

function M.evaluate(id)
  local def = M.devices[id]
  local conn = M.audioConnected(def.name)
  local was = lastConnected[id]
  lastConnected[id] = conn
  if conn then
    if not was then setArmed(id, true) end
    stopWatch(id)
  elseif M.state[id].armed and not watches[id] and not watchRestarts[id] then
    startWatch(id)
  end
end

if #autoIds > 0 then
  require("modules.audio_events").subscribe(function(event)
    if event ~= "dev#" then return end
    for _, id in ipairs(autoIds) do M.evaluate(id) end
  end)
  -- 로드 시점 상태 반영 (리로드 전 무장 기록은 hs.settings 에서 복원됨)
  for _, id in ipairs(autoIds) do M.evaluate(id) end
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
    local w = watches[id]
    log.f("  %s: connected=%s armed=%s watch=%s", id, tostring(isConnected(def)),
          tostring(M.state[id].armed), w and w.mode or "-")
  end
end

_G.btDevice = M   -- Hammerspoon 콘솔에서 접근용
return M
