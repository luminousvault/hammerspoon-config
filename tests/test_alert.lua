--------------------------------------------------------------------------------
-- tests/test_alert.lua — 공통 알림 모듈 테스트
--------------------------------------------------------------------------------

local Alert = require("modules.alert")

return {
  {
    name = "show 후 duration 지나면 사라짐",
    fn = function(t)
      Alert.show("test: lifecycle", { duration = Alert.Duration.SHORT })
      t.truthy(Alert.canvas, "canvas visible after show")
      t.sleep(Alert.Duration.SHORT + 0.5)   -- 표시 + 페이드아웃 대기
      t.eq(Alert.canvas, nil, "canvas removed after duration")
    end,
  },
  {
    name = "TOP/CENTER/BOTTOM 세 위치 모두 표시",
    fn = function(t)
      for _, pos in pairs(Alert.Position) do
        Alert.show("test: " .. pos, { position = pos, duration = Alert.Duration.SHORT })
        t.truthy(Alert.canvas, "canvas at " .. pos)
        t.sleep(0.2)
      end
      t.sleep(1)
    end,
  },
  {
    name = "글자 배지 / 아이콘 배지",
    fn = function(t)
      Alert.show("test: text badge", { badge = "가", duration = Alert.Duration.SHORT })
      t.truthy(Alert.canvas, "text badge shown")
      t.sleep(1)

      local icon = Alert.whiteIcon("NSTouchBarAudioOutputMuteTemplate")
      t.truthy(icon, "whiteIcon returns an image")
      Alert.show("test: icon badge", { badge = icon, duration = Alert.Duration.SHORT })
      t.truthy(Alert.canvas, "icon badge shown")
      t.sleep(1)
    end,
  },
  {
    name = "새 알림이 이전 알림을 대체",
    fn = function(t)
      Alert.show("test: first", { duration = Alert.Duration.LONG })
      local first = Alert.canvas
      Alert.show("test: second", { duration = Alert.Duration.SHORT })
      t.truthy(Alert.canvas, "second alert shown")
      t.truthy(Alert.canvas ~= first, "previous canvas replaced")
      t.sleep(1)
    end,
  },
}
