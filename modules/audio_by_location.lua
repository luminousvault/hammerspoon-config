--------------------------------------------------------------------------------
-- audio_by_location.lua
--
-- Wi-Fi SSID 기준으로 오디오 출력 상태를 자동 전환합니다.
--
-- 장소는 local_config.lua 에서 자유롭게 정의합니다 (이름·개수 제한 없음).
-- 장소마다 아래 정책을 지정할 수 있습니다:
--   ssids         : 이 장소로 인식할 SSID 목록
--   name          : 알림에 표시할 이름 (생략 시 장소 id)
--   audio         : 기본 오디오 상태 { muted, volume }
--   learn         : true 면 떠날 때 상태를 기억해두고 돌아오면 복원
--                   (false 면 항상 audio 고정값 적용 — 예: 회사는 음소거 고정)
--   speakerOnly   : true 면 정책을 스피커류(내장/HDMI/DisplayPort)에만 적용.
--                   블루투스 이어폰 등 개인 기기는 건드리지 않음
--   enforceOnWake : true 면 절전 복귀 시 저장값을 강제로 재적용
--
-- 설치
--   1) ~/.hammerspoon/init.lua 에 아래 한 줄 추가
--        require("modules.audio_by_location")
--   2) local_config.example.lua 를 local_config.lua 로 복사해 장소 정의
--   3) 시스템 설정 → 개인정보 보호 및 보안 → 위치 서비스 에서 Hammerspoon 허용
--      (Sonoma 이후 SSID 조회에 위치 권한 필요. 없으면 SSID 가 항상 nil)
--------------------------------------------------------------------------------

local Alert = require("modules.alert")

local M = {}

--------------------------------------------------------------------------------
-- 설정
--------------------------------------------------------------------------------

-- 장소 정의. SSID 등 개인정보가 포함되므로 로컬 전용 파일에서 읽습니다.
-- (~/.hammerspoon/local_config.lua — 없으면 local_config.example.lua 를 복사해 작성)
local ok, localConfig = pcall(require, "local_config")
if not ok then
  -- pcall 실패 시 localConfig 에 에러 메시지가 들어 있음 (파일 없음/문법 오류 구분용)
  print("[audio_by_location] failed to load local_config.lua: " .. tostring(localConfig))
  print("[audio_by_location] if the file is missing, copy local_config.example.lua to create it")
  localConfig = {}
end

-- 장소 id → 장소 정의
local PLACES = localConfig.places or {}

-- SSID → 장소 id 역인덱스
local SSID_TO_PLACE = {}
for id, def in pairs(PLACES) do
  for _, ssid in ipairs(def.ssids or {}) do
    SSID_TO_PLACE[ssid] = id
  end
end

-- 알림에 표시할 문자열. 사용자 언어에 맞게 수정하세요. (로그는 항상 영어)
local STRINGS = {
  muted      = "음소거",
  volume     = "볼륨 %d%%",
  resetDone  = "오디오 학습값 초기화",
}

-- 알림 배지용 스피커 아이콘 (메뉴 막대와 같은 시스템 템플릿 이미지)
local ICON_SOUND = Alert.whiteIcon("NSTouchBarAudioOutputVolumeHighTemplate")
local ICON_MUTE  = Alert.whiteIcon("NSTouchBarAudioOutputMuteTemplate")

-- 스피커류로 간주하는 transport (hs.audiodevice:transportType())
local SPEAKER_TRANSPORTS = {
  ["Built-in"]    = true,
  ["HDMI"]        = true,
  ["DisplayPort"] = true,
}

-- SSID 확정 대기 시간(초). DHCP/DNS 가 올라올 시간을 줍니다.
local SETTLE      = 2
-- 절전 복귀 후 Wi-Fi 재연결 대기 시간(초)
local WAKE_SETTLE = 6

local LOG_KEY   = "audio.place"   -- 현재 장소 저장 키
local NOTIFY    = true            -- true 면 전환 시 알림 표시

--------------------------------------------------------------------------------
-- 내부 유틸
--------------------------------------------------------------------------------

local log = hs.logger.new("audioLoc", "info")

local function device()
  return hs.audiodevice.defaultOutputDevice()
end

-- 저장 키를 장소 + 출력기기 UID 로 만듭니다.
-- 볼륨은 기기별로 따로 관리되므로, 이어폰/외장 모니터가 붙어 있을 때
-- 내장 스피커 설정을 덮어쓰는 문제를 막아줍니다.
local function key(place, dev)
  dev = dev or device()
  local uid = dev and dev:uid() or "unknown"
  return "audio.state." .. place .. "." .. uid
end

local function currentPlace()
  local ssid = hs.wifi.currentNetwork()
  if not ssid then return nil end        -- 유선 랜 / 권한 없음 / 미연결
  return SSID_TO_PLACE[ssid]
end

--------------------------------------------------------------------------------
-- 저장 / 복원
--------------------------------------------------------------------------------

-- 지금 오디오 상태를 해당 장소의 값으로 저장
function M.save(place, dev)
  local def = place and PLACES[place]
  if not (def and def.learn) then return end   -- 고정값 장소는 저장하지 않음

  dev = dev or device()
  if not dev then return end

  local state = { muted = dev:muted() }
  local vol = dev:volume()               -- HDMI 등 일부 기기는 nil 반환
  if vol then state.volume = vol end

  hs.settings.set(key(place, dev), state)
  log.f("save %s → muted=%s volume=%s", place,
        tostring(state.muted), tostring(state.volume))
end

-- 해당 장소의 저장값(없으면 기본값)을 적용
function M.restore(place, dev)
  local def = place and PLACES[place]
  if not def then return end

  dev = dev or device()
  if not dev then return end

  -- 스피커류 전용 정책인 장소에서, 개인 기기가 기본 출력이면 적용하지 않음
  if def.speakerOnly and not SPEAKER_TRANSPORTS[dev:transportType()] then
    log.f("skip %s → %s (transport=%s, not a speaker)",
          place, dev:name(), tostring(dev:transportType()))
    return
  end

  local state = def.learn and hs.settings.get(key(place, dev)) or nil
  state = state or def.audio
  if not state then return end

  -- 적용 전 상태를 기억해서 실제로 바뀌었을 때만 알림
  local wasMuted  = dev:muted()
  local wasVolume = dev:volume()

  if state.muted ~= nil then dev:setMuted(state.muted) end
  if state.volume       then dev:setVolume(state.volume) end

  log.f("restore %s → muted=%s volume=%s", place,
        tostring(state.muted), tostring(state.volume))

  local changed = (state.muted ~= nil and state.muted ~= wasMuted)
    or (state.volume and wasVolume
        and math.floor(state.volume) ~= math.floor(wasVolume))

  if NOTIFY and changed then
    local desc = state.muted and STRINGS.muted
      or STRINGS.volume:format(math.floor(state.volume or 0))
    Alert.show((def.name or place) .. " · " .. desc, {
      badge    = state.muted and ICON_MUTE or ICON_SOUND
    })
  end
end

--------------------------------------------------------------------------------
-- 전환 처리
--------------------------------------------------------------------------------

local debounce

-- force = true 면 장소가 같아도 복원을 다시 실행
local function apply(force)
  local place = currentPlace()
  local prev  = hs.settings.get(LOG_KEY)

  if place == prev and not force then return end

  if place ~= prev then
    M.save(prev)                         -- 떠나기 전 상태 기억
    hs.settings.set(LOG_KEY, place)
  end

  M.restore(place)
end

-- Wi-Fi 워처는 연결 한 번에 여러 번 발동하므로 디바운스가 필요합니다.
local function schedule(force)
  if debounce then debounce:stop() end
  debounce = hs.timer.doAfter(SETTLE, function() apply(force) end)
end

--------------------------------------------------------------------------------
-- 워처
--------------------------------------------------------------------------------

M.wifi = hs.wifi.watcher.new(function() schedule(false) end):start()

M.sleep = hs.caffeinate.watcher.new(function(event)
  if event ~= hs.caffeinate.watcher.systemDidWake then return end

  schedule(false)                        -- 장소가 바뀐 채로 깨어난 경우

  -- Wi-Fi 가 다시 붙은 뒤, 강제 적용 대상이면 한 번 더
  -- 주의: doAfter 타이머도 참조를 유지해야 합니다. 참조 없이 만들면
  --       발화 전에 GC 가 수거해서 조용히 사라질 수 있습니다. (아래 동일)
  M.wakeTimer = hs.timer.doAfter(WAKE_SETTLE, function()
    local place = currentPlace()
    local def = place and PLACES[place]
    if def and def.enforceOnWake then M.restore(place) end
  end)
end):start()

-- 출력 기기가 바뀌면(블루투스 이어폰 재연결, HDMI 재인식 등) 그 기기 기준으로 재적용
-- 주의: hs.audiodevice.watcher 콜백은 Hammerspoon 전체에 하나만 등록됩니다.
--       다른 모듈에서 setCallback 을 부르면 서로 덮어씁니다.
hs.audiodevice.watcher.setCallback(function(event)
  if event ~= "dOut" then return end
  local place = currentPlace()
  if not place then return end
  M.devTimer = hs.timer.doAfter(1, function() M.restore(place) end)
end)
hs.audiodevice.watcher.start()

--------------------------------------------------------------------------------
-- 콘솔용 함수 (Hammerspoon 콘솔에서 audioLoc.xxx() 로 호출)
--------------------------------------------------------------------------------

-- 현재 장소 설정을 즉시 재적용. 동작 테스트용.
function M.reapply()
  local place = currentPlace()
  if not place then
    log.w("not a registered place (SSID: " ..
      tostring(hs.wifi.currentNetwork()) .. ")")
    return
  end
  M.restore(place)
end

-- 지금 상태를 현재 장소의 값으로 저장. 학습 대상 장소에서만 동작.
function M.pin()
  local place = currentPlace()
  local def = place and PLACES[place]
  if not (def and def.learn) then
    log.w("not a learning place: " .. tostring(place))
    return
  end
  M.save(place)
end

-- 현재 인식된 장소 id (콘솔/테스트용)
function M.currentPlace()
  return currentPlace()
end

-- 장소 정의 조회 (콘솔/테스트용)
function M.placeDef(id)
  return PLACES[id]
end

-- 현재 상태 확인
function M.status()
  local dev = device()
  log.f("SSID=%s place=%s device=%s muted=%s volume=%s",
    tostring(hs.wifi.currentNetwork()),
    tostring(currentPlace()),
    dev and dev:name() or "nil",
    dev and tostring(dev:muted()) or "nil",
    dev and tostring(dev:volume()) or "nil")
end

-- 학습값 초기화. 저장 키가 장소+기기 UID 단위이므로 모든 출력 기기를 순회합니다.
function M.reset()
  for placeId in pairs(PLACES) do
    for _, dev in ipairs(hs.audiodevice.allOutputDevices()) do
      hs.settings.clear(key(placeId, dev))
    end
  end
  hs.settings.clear(LOG_KEY)
  Alert.show(STRINGS.resetDone)
end

--------------------------------------------------------------------------------
-- 초기 적용
--------------------------------------------------------------------------------

-- 리로드 직후 SSID 조회가 아직 안 될 수 있으므로 살짝 늦춰서 실행.
-- 리로드로 볼륨이 튀는 게 싫으면 아래 두 줄을 주석 처리하세요.
M.initTimer = hs.timer.doAfter(1, function() apply(false) end)

_G.audioLoc = M   -- Hammerspoon 콘솔에서 접근용
return M
