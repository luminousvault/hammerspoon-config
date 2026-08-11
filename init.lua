-- Hammerspoon API : http://www.hammerspoon.org/docs/index.html
-- MAC 키보드 기본 단축키 : https://support.apple.com/ko-kr/HT201236

hs.hotkey.bind({"cmd", "alt", "ctrl"}, "R", hs.reload)

local Alert = require("modules.alert")
Alert.show("🔨 Hammerspoon 설정 로드 완료")   -- 중앙, 2초 (기본값)

require("hs.ipc")  -- 터미널 hs CLI 연동

require("modules.input_source")
require("modules.audio_by_location")
