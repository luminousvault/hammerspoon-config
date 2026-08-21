--------------------------------------------------------------------------------
-- input_source.lua
--
-- 오른쪽 커맨드 키 단독 입력 시 한/영 전환.
-- 다른 키와 조합해서 누르면 일반 커맨드 키로 동작합니다.
--
-- 롤(roll) 보호: 전환하려고 오른쪽 커맨드를 탭한 뒤 손을 완전히 떼기 전에
-- 다음 글자를 누르면 macOS 가 cmd+space, cmd+f 같은 단축키로 처리해버립니다.
-- 이를 막기 위해 오른쪽 커맨드를 누르고 ROLL_WINDOW 초 안에 들어온 키는
-- 단축키가 아니라 "전환 직후 타이핑"으로 간주하여, 단축키를 차단하고
-- 즉시 전환한 뒤 그 키를 새 입력 소스로 다시 입력합니다.
-- 오른쪽 커맨드로 단축키를 쓰려면 ROLL_WINDOW 이상 누른 뒤 조합하면 되고,
-- SHORTCUT_KEYS 에 등록된 키(기본: ",")는 시간과 무관하게 항상 단축키로
-- 동작합니다 (cmd+, 설정 열기 용).
--
-- 전환 시 포커스된 모니터 하단에 [한]/[A] 배지 + 이름("두벌식", "ABC") 알림을
-- 잠깐 표시합니다 (그리기는 modules/alert.lua 담당). 알림 모드 3가지:
--   ALL    - 모든 전환에 표시 (시스템/앱이 바꾼 것 포함)
--   MANUAL - 이 모듈의 전환(오른쪽 커맨드 등)으로 바뀔 때만 표시
--   OFF    - 표시 안 함
-- 기본값은 아래 ALERT_MODE 로, 실행 중에는 콘솔에서
-- inputSource.setAlertMode("manual") 처럼 바꿀 수 있습니다.
--
-- 설치
--   1) ~/.hammerspoon/init.lua 에 아래 한 줄 추가
--        require("modules.input_source")
--   2) 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 에서 Hammerspoon 허용
--      (eventtap 은 손쉬운 사용 권한이 필요. 위치 서비스와는 무관)
--
-- 주의: hs.keycodes.inputSourceChanged 콜백은 Hammerspoon 전체에 하나만
--       등록됩니다. 다른 모듈에서 같은 콜백을 등록하면 서로 덮어씁니다.
--------------------------------------------------------------------------------

local Alert = require("modules.alert")

local M = {}

--------------------------------------------------------------------------------
-- 설정
--------------------------------------------------------------------------------

local ENGLISH = "com.apple.keylayout.ABC"
local KOREAN  = "com.apple.inputmethod.Korean.2SetKorean"

local RIGHT_CMD_KEYCODE = 54   -- 왼쪽 커맨드는 55

-- 롤 보호: 오른쪽 커맨드를 누르고 이 시간(초) 안에 들어온 키는 단축키가
-- 아니라 "전환 직후 타이핑"으로 간주합니다. 오른쪽 커맨드로 단축키를
-- 조합하려면 이 시간 이상 누른 뒤 다른 키를 누르세요.
local ROLL_WINDOW = 0.2

-- 롤 창 안이라도 항상 단축키로 인정할 키 (오른쪽 cmd+, 로 설정 열기 등)
local SHORTCUT_KEYS = { "," }

-- 롤로 삼킨 키를 다시 입력하기 전 대기 시간(초).
-- 입력 소스 전환이 앱에 반영될 틈을 줍니다. 새 소스가 아닌 이전 소스의
-- 글자가 입력되는 일이 잦으면 이 값을 조금 올리세요.
local RETYPE_DELAY = 0.06

-- 전환 알림 모드
M.AlertMode = {
  ALL    = "all",      -- 모든 전환에 표시 (시스템/앱이 바꾼 것 포함)
  MANUAL = "manual",   -- 이 모듈의 전환으로 바뀔 때만 표시
  OFF    = "off",      -- 표시 안 함
}

local ALERT_MODE = M.AlertMode.MANUAL   -- 기본값

-- 알림에 쓸 입력 소스 표시 정보. 키는 Hammerspoon 이 주는 내부 영문 이름
-- (macOS 메뉴 막대가 쓰는 현지화 이름은 API 로 노출되지 않음).
-- 매핑에 없는 소스는 내부 이름 그대로 + 첫 글자 배지로 표시됩니다.
local SOURCES = {
  ["2-Set Korean"] = { badge = "한", name = "두벌식" },
  ["ABC"]          = { badge = "A",  name = "ABC" },
}

--------------------------------------------------------------------------------
-- 상태
--------------------------------------------------------------------------------

local rightCmdPressed = false
local otherKeyPressed = false
local rightCmdDownAt  = 0       -- 오른쪽 커맨드가 눌린 시각
local rolling         = false   -- 롤 감지됨: 커맨드를 뗄 때까지 cmd 조합 차단
local retypeTimers    = {}      -- 재입력 타이머 참조 유지 (GC 방지)

-- 이 모듈이 다시 쏜 합성 키 이벤트의 표식. 워처가 자기가 만든 이벤트를
-- 또 삼키는 무한 루프를 막습니다. (0x48414E = "HAN")
local SYNTH_TAG = 0x48414E

local SHORTCUT_KEYCODES = {}
for _, key in ipairs(SHORTCUT_KEYS) do
  local code = hs.keycodes.map[key]
  if code then SHORTCUT_KEYCODES[code] = true end
end

-- 이 모듈의 전환 함수가 마지막으로 호출된 시각.
-- 불리언 플래그 대신 타임스탬프를 쓰는 이유: 전환 함수를 불렀는데 실제 전환이
-- 일어나지 않으면(대상 소스가 제거된 경우 등) 콜백이 안 불려서 플래그가 남고,
-- 이후 시스템 전환 1회가 수동으로 오인됩니다. 시간 창으로 판정하면 자연 소멸.
local manualChangeAt = 0
local MANUAL_WINDOW  = 0.5   -- 전환 함수 호출 후 이 시간(초) 안의 변경만 수동으로 인정

M.alertMode  = ALERT_MODE
M.lastSource = hs.keycodes.currentSourceID()
M.ENGLISH    = ENGLISH   -- 다른 모듈에서 "영어 모드인지" 판별용 (caps_lock 등)

--------------------------------------------------------------------------------
-- 전환
--------------------------------------------------------------------------------

function M.toggle()
  manualChangeAt = hs.timer.secondsSinceEpoch()
  if hs.keycodes.currentSourceID() == ENGLISH then
    hs.keycodes.currentSourceID(KOREAN)
  else
    hs.keycodes.currentSourceID(ENGLISH)
  end
end

function M.toEnglish()
  manualChangeAt = hs.timer.secondsSinceEpoch()
  hs.keycodes.currentSourceID(ENGLISH)
end

function M.toKorean()
  manualChangeAt = hs.timer.secondsSinceEpoch()
  hs.keycodes.currentSourceID(KOREAN)
end

--------------------------------------------------------------------------------
-- 전환 알림
--------------------------------------------------------------------------------

-- 현재 입력 소스의 배지 글자와 표시 이름.
-- 입력기 이름(예: "2-Set Korean") 우선, 없으면 자판 레이아웃 이름(예: "ABC")
local function sourceInfo()
  local name = hs.keycodes.currentMethod()
      or hs.keycodes.currentLayout()
      or hs.keycodes.currentSourceID()
  local source = SOURCES[name]
  if source then
    return source.badge, source.name
  end
  -- UTF-8 안전하게 첫 글자 추출 (sub(1,1) 은 바이트 단위라 한글 등이 깨짐)
  local firstChar = name:match("[%z\1-\127\194-\244][\128-\191]*") or "?"
  return firstChar:upper(), name
end

local function showSourceAlert()
  local badge, name = sourceInfo()
  Alert.show(name, {
    badge    = badge,
    position = Alert.Position.BOTTOM,
    duration = Alert.Duration.SHORT,
  })
end

hs.keycodes.inputSourceChanged(function()
  local src = hs.keycodes.currentSourceID()
  if src == M.lastSource then return end   -- 콜백이 중복 호출되는 경우 방지
  M.lastSource = src

  local wasManual =
    (hs.timer.secondsSinceEpoch() - manualChangeAt) < MANUAL_WINDOW
  manualChangeAt = 0

  if M.alertMode == M.AlertMode.OFF then return end
  if M.alertMode == M.AlertMode.MANUAL and not wasManual then return end
  showSourceAlert()
end)

--------------------------------------------------------------------------------
-- 워처
--
-- 주의: eventtap 객체는 반드시 참조를 유지해야 합니다.
--       local 변수에만 담아두면 가비지 컬렉터가 회수해서
--       어느 순간 조용히 동작이 멈춥니다. 그래서 M 에 담습니다.
--------------------------------------------------------------------------------

-- 롤로 삼킨 키를 cmd 없이 다시 입력. 테스트에서 교체할 수 있게 M 에 둡니다.
function M._postKey(mods, keycode)
  local down = hs.eventtap.event.newKeyEvent(mods, keycode, true)
  local up   = hs.eventtap.event.newKeyEvent(mods, keycode, false)
  down:setProperty(hs.eventtap.event.properties.eventSourceUserData, SYNTH_TAG)
  up:setProperty(hs.eventtap.event.properties.eventSourceUserData, SYNTH_TAG)
  down:post()
  up:post()
end

-- 입력 소스 전환이 반영된 뒤 키를 다시 입력하도록 예약
local function retypeLater(event)
  local keycode = event:getKeyCode()
  local flags   = event:getFlags()
  local mods = {}
  if flags.shift then mods[#mods + 1] = "shift" end
  if flags.fn    then mods[#mods + 1] = "fn"    end
  local timer
  timer = hs.timer.doAfter(RETYPE_DELAY, function()
    retypeTimers[timer] = nil
    M._postKey(mods, keycode)
  end)
  retypeTimers[timer] = true
end

local function onFlagsChanged(event)
  if event:getKeyCode() == RIGHT_CMD_KEYCODE then
    if event:getFlags().cmd then
      -- 오른쪽 커맨드 눌림
      rightCmdPressed = true
      otherKeyPressed = false
      rolling         = false
      rightCmdDownAt  = hs.timer.secondsSinceEpoch()
    else
      -- 오른쪽 커맨드 뗌: 사이에 다른 키를 안 눌렀으면 한/영 전환
      if rightCmdPressed and not otherKeyPressed then
        M.toggle()
      end
      rightCmdPressed = false
      rolling         = false
    end
  else
    -- 다른 모디파이어 키가 섞이면 단독 입력이 아님
    if rightCmdPressed then
      otherKeyPressed = true
    end
  end
  return false   -- 반드시 false. 키 이벤트를 통과시켜야 합니다.
end

-- 오른쪽 커맨드를 누른 채 들어온 keyDown 처리.
-- true 를 반환하면 원본 이벤트(cmd 조합)가 삭제됩니다.
local function onKeyDown(event)
  if not rightCmdPressed then return false end

  -- 우리가 다시 쏜 합성 이벤트는 그대로 통과
  if event:getProperty(hs.eventtap.event.properties.eventSourceUserData)
      == SYNTH_TAG then
    return false
  end

  local flags = event:getFlags()
  local withinRoll =
    (hs.timer.secondsSinceEpoch() - rightCmdDownAt) < ROLL_WINDOW
  local isShortcut = SHORTCUT_KEYCODES[event:getKeyCode()]
      or flags.ctrl or flags.alt   -- 모디파이어가 더 섞이면 의도한 조합

  if rolling or (withinRoll and not isShortcut) then
    -- 타이핑 롤: 전환하려던 것인데 커맨드를 떼기 전에 다음 키를 누른 것.
    -- 단축키 대신 즉시 전환하고, 그 키를 새 입력 소스로 다시 입력합니다.
    if not rolling then
      rolling = true
      M.toggle()
    end
    otherKeyPressed = true   -- 커맨드를 뗄 때 또 전환되지 않게
    retypeLater(event)
    return true
  end

  -- 단축키 조합으로 간주
  otherKeyPressed = true
  return false
end

M._onFlagsChanged = onFlagsChanged   -- 테스트용
M._onKeyDown      = onKeyDown        -- 테스트용

M.flagsWatcher = hs.eventtap.new(
  { hs.eventtap.event.types.flagsChanged }, onFlagsChanged)

M.keyWatcher = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown }, onKeyDown)

M.flagsWatcher:start()
M.keyWatcher:start()

--------------------------------------------------------------------------------
-- 콘솔용
--------------------------------------------------------------------------------

-- 전환 알림 모드 변경: "all" / "manual" / "off"
function M.setAlertMode(mode)
  for _, v in pairs(M.AlertMode) do
    if v == mode then
      M.alertMode = mode
      print("input source alert mode: " .. mode)
      return
    end
  end
  print('invalid mode. use "all", "manual" or "off"')
end

-- 알림 미리보기
function M.previewAlert()
  showSourceAlert()
end

-- 동작이 멈춘 것 같을 때 확인
function M.status()
  print(string.format(
    "flagsWatcher=%s keyWatcher=%s alertMode=%s current=%s",
    tostring(M.flagsWatcher and M.flagsWatcher:isEnabled()),
    tostring(M.keyWatcher and M.keyWatcher:isEnabled()),
    tostring(M.alertMode),
    tostring(hs.keycodes.currentSourceID())
  ))
end

function M.restart()
  if M.flagsWatcher then M.flagsWatcher:stop():start() end
  if M.keyWatcher   then M.keyWatcher:stop():start()   end
end

_G.inputSource = M   -- Hammerspoon 콘솔에서 접근용
return M
