--------------------------------------------------------------------------------
-- alert.lua
--
-- hs.alert 를 대체하는 공통 알림 모듈.
-- hs.alert 는 가장자리 여백·디자인을 조절할 수 없어서 hs.canvas 로 직접 그립니다.
-- 회색 반투명 박스 + 검은 텍스트, 앞에 선택적으로 배지(한/A 같은)를 붙일 수 있음.
--
-- 사용법
--   local Alert = require("modules.alert")
--
--   Alert.show("메시지")                                   -- 중앙, 2초 (hs.alert 와 동일)
--   Alert.show("두벌식", {
--     badge      = "한",                                   -- 앞에 붙는 강조 배지 (생략 가능)
--     badgeColor = { red = 1, green = 0.42, blue = 0 },    -- 배지 배경색 (생략 시 짙은 회색)
--     position   = Alert.Position.BOTTOM,                  -- TOP / CENTER / BOTTOM
--     duration   = Alert.Duration.SHORT,                   -- SHORT / NORMAL / LONG
--     minWidth   = 120,                                    -- 박스 최소 너비 px (생략 시 72).
--                                                          -- 번갈아 뜨는 알림의 박스 크기를
--                                                          -- 맞출 때 사용 (예: caps ABC/abc)
--   })
--
--   badge 는 문자열(한 글자) 또는 hs.image 를 받습니다. 시스템 템플릿 아이콘을
--   배지에 넣을 땐 Alert.whiteIcon("NS...Template") 으로 흰색 틴트해서 전달하세요.
--
-- 알림은 한 번에 하나만 표시됩니다 (새 알림이 이전 알림을 대체).
--------------------------------------------------------------------------------

local M = {}

--------------------------------------------------------------------------------
-- 공개 규격 (enum)
--------------------------------------------------------------------------------

-- 표시 시간 (초)
M.Duration = {
  SHORT  = 0.6,   -- 한/영 전환처럼 스쳐 지나가듯 확인하는 알림
  NORMAL = 2.0,   -- hs.alert 기본값과 동일
  LONG   = 4.0,   -- 내용을 읽어야 하는 알림
}

-- 표시 위치 (포커스된 모니터 기준)
M.Position = {
  TOP    = "top",
  CENTER = "center",
  BOTTOM = "bottom",
}

--------------------------------------------------------------------------------
-- 디자인 규격
--------------------------------------------------------------------------------

local BOX_MIN_W      = 72     -- 박스 최소 너비 (실제 너비는 내용에 맞춰 늘어남)
local BOX_PADDING_H  = 18     -- 내용 좌우 여백
local BOX_H          = 52     -- 박스 높이
local MARGIN_TOP     = 48     -- TOP 일 때 화면 상단 여백 (px)
local MARGIN_BOTTOM  = 140    -- BOTTOM 일 때 화면 하단 여백 (px).
                              -- 하단 입력창(채팅 등)을 가리지 않도록 넉넉하게.
local CORNER_RADIUS  = 12
local FADE_IN        = 0.1
local FADE_OUT       = 0.2

local BADGE_SIZE      = 28    -- 배지 한 변 크기
local BADGE_RADIUS    = 7
local BADGE_TEXT_SIZE = 15
local BADGE_GAP       = 10    -- 배지와 텍스트 사이 간격

local TEXT_SIZE = 20

local BOX_COLOR        = { white = 0.8, alpha = 0.8 }
local TEXT_COLOR       = { white = 0, alpha = 1 }
local BADGE_COLOR      = { white = 0.25, alpha = 0.95 }
local BADGE_TEXT_COLOR = { white = 1, alpha = 1 }

--------------------------------------------------------------------------------
-- 구현
--------------------------------------------------------------------------------

local function closeAlert()
  if M.hideTimer   then M.hideTimer:stop()   M.hideTimer   = nil end
  if M.deleteTimer then M.deleteTimer:stop() M.deleteTimer = nil end
  if M.canvas      then M.canvas:delete()    M.canvas      = nil end
end

-- opts: { badge?, badgeColor?, position?, duration?, minWidth? }
function M.show(text, opts)
  opts = opts or {}
  local badge      = opts.badge
  local badgeColor = opts.badgeColor or BADGE_COLOR
  local position   = opts.position or M.Position.CENTER
  local duration   = opts.duration or M.Duration.NORMAL
  local minWidth   = opts.minWidth or BOX_MIN_W

  closeAlert()

  M.canvas = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
  M.canvas[1] = {   -- 바탕 박스
    type = "rectangle",
    action = "fill",
    roundedRectRadii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS },
    fillColor = BOX_COLOR,
  }
  M.canvas[2] = {   -- 본문 텍스트
    type = "text",
    text = text,
    textSize = TEXT_SIZE,
    textColor = TEXT_COLOR,
    textAlignment = "left",
  }

  local textSize = M.canvas:minimumTextSize(2, text)
  local textW = math.ceil(textSize.w) + 4   -- 반올림 잘림 방지 여유

  -- 배지 유무에 따라 가로 배치 계산
  local badgeSpan = badge and (BADGE_SIZE + BADGE_GAP) or 0
  local boxW = math.max(minWidth, BOX_PADDING_H + badgeSpan + textW + BOX_PADDING_H)

  -- 최소 너비(BOX_MIN_W)가 적용돼 박스가 내용보다 넓어지면 내용을 가운데로
  local contentX = (boxW - badgeSpan - textW) / 2

  M.canvas[2].frame = {
    x = contentX + badgeSpan,
    y = (BOX_H - textSize.h) / 2,
    w = textW,
    h = textSize.h,
  }

  if badge then
    local badgeY = (BOX_H - BADGE_SIZE) / 2
    M.canvas[3] = {   -- 배지 박스
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = BADGE_RADIUS, yRadius = BADGE_RADIUS },
      fillColor = badgeColor,
      frame = { x = contentX, y = badgeY, w = BADGE_SIZE, h = BADGE_SIZE },
    }
    if type(badge) == "string" then
      M.canvas[4] = {   -- 배지 글자
        type = "text",
        text = badge,
        textSize = BADGE_TEXT_SIZE,
        textColor = BADGE_TEXT_COLOR,
        textAlignment = "center",
      }
      local badgeText = M.canvas:minimumTextSize(4, badge)
      M.canvas[4].frame = {
        x = contentX,
        y = badgeY + (BADGE_SIZE - badgeText.h) / 2,
        w = BADGE_SIZE,
        h = badgeText.h,
      }
    else
      local inset = 5   -- 배지 박스 안 아이콘 여백
      M.canvas[4] = {   -- 배지 아이콘 (hs.image)
        type = "image",
        image = badge,
        imageScaling = "scaleProportionally",
        frame = {
          x = contentX + inset,
          y = badgeY + inset,
          w = BADGE_SIZE - inset * 2,
          h = BADGE_SIZE - inset * 2,
        },
      }
    end
  end

  -- frame() 은 메뉴바·독을 제외한 영역 (포커스된 모니터 기준)
  local frame = hs.screen.mainScreen():frame()
  local y
  if position == M.Position.TOP then
    y = frame.y + MARGIN_TOP
  elseif position == M.Position.BOTTOM then
    y = frame.y + frame.h - BOX_H - MARGIN_BOTTOM
  else
    y = frame.y + (frame.h - BOX_H) / 2
  end
  M.canvas:frame({
    x = frame.x + (frame.w - boxW) / 2,
    y = y,
    w = boxW,
    h = BOX_H,
  })
  M.canvas:level(hs.canvas.windowLevels.overlay)
  M.canvas:show(FADE_IN)

  M.hideTimer = hs.timer.doAfter(duration, function()
    if M.canvas then M.canvas:hide(FADE_OUT) end
    M.deleteTimer = hs.timer.doAfter(FADE_OUT, closeAlert)
  end)
end

-- 시스템 템플릿 이미지(검은색)를 흰색으로 틴트해서 배지용 아이콘으로 만듭니다.
-- 예: Alert.whiteIcon("NSTouchBarAudioOutputMuteTemplate")
function M.whiteIcon(templateName)
  local src = hs.image.imageFromName(templateName)
  if not src then return nil end

  local size = 64   -- 배지보다 크게 그려두고 표시할 때 축소 (선명도 확보)
  local c = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
  c[1] = { type = "image", image = src, imageScaling = "scaleProportionally" }
  c[2] = { type = "image", image = src, imageScaling = "scaleProportionally" }   -- 두 번 겹쳐 알파 보강
  c[3] = { type = "rectangle", action = "fill",
           fillColor = { white = 1, alpha = 1 }, compositeRule = "sourceAtop" }
  local img = c:imageFromCanvas()
  c:delete()
  return img
end

_G.customAlert = M   -- Hammerspoon 콘솔에서 접근용
return M
