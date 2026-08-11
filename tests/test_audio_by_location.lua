--------------------------------------------------------------------------------
-- tests/test_audio_by_location.lua — 장소별 오디오 모듈 테스트
--
-- 현재 접속한 Wi-Fi/장소/기기 구성에 따라 전제 조건이 안 맞는 테스트는
-- SKIP 처리됩니다 (예: 등록되지 않은 SSID 에서 실행).
--------------------------------------------------------------------------------

local AL = require("modules.audio_by_location")

local SPEAKER_TRANSPORTS = {
  ["Built-in"] = true, ["HDMI"] = true, ["DisplayPort"] = true,
}

local function findOutput(transport)
  for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
    if d:transportType() == transport then return d end
  end
end

return {
  {
    name = "장소 인식 (local_config 로드)",
    fn = function(t)
      local place = AL.currentPlace()
      if not place then t.skip("not at a registered place") end
      t.truthy(AL.placeDef(place), "place definition exists")
    end,
  },
  {
    name = "speakerOnly 장소에서 개인 기기는 건드리지 않음",
    fn = function(t)
      local place = AL.currentPlace()
      if not place then t.skip("not at a registered place") end
      local def = AL.placeDef(place)
      if not def.speakerOnly then t.skip("place is not speakerOnly") end

      local dev = hs.audiodevice.defaultOutputDevice()
      if SPEAKER_TRANSPORTS[dev:transportType()] then
        t.skip("default output is a speaker (" .. dev:transportType() .. ")")
      end

      local muted, volume = dev:muted(), dev:volume()
      AL.restore(place)
      t.eq(dev:muted(), muted, "muted unchanged")
      t.eq(dev:volume(), volume, "volume unchanged")
    end,
  },
  {
    name = "고정 정책이 내장 스피커에 적용됨",
    fn = function(t)
      local place = AL.currentPlace()
      if not place then t.skip("not at a registered place") end
      local def = AL.placeDef(place)
      if def.learn or not def.audio or def.audio.muted == nil then
        t.skip("place has no fixed muted policy")
      end

      local speaker = findOutput("Built-in")
      if not speaker then t.skip("no built-in speaker") end

      local prevMuted = speaker:muted()
      speaker:setMuted(not def.audio.muted)     -- 정책과 반대로 틀어두고
      AL.restore(place, speaker)                -- 정책 적용
      local applied = speaker:muted()
      speaker:setMuted(prevMuted)               -- 원상복구
      t.sleep(1)                                -- 알림 소멸 대기
      t.eq(applied, def.audio.muted, "fixed policy applied to speaker")
    end,
  },
  {
    name = "학습 안 하는 장소에서 pin() 거부",
    fn = function(t)
      local place = AL.currentPlace()
      if not place then t.skip("not at a registered place") end
      local def = AL.placeDef(place)
      if def.learn then t.skip("place is a learning place") end

      local dev = hs.audiodevice.defaultOutputDevice()
      local settingsKey = "audio.state." .. place .. "." .. (dev:uid() or "unknown")
      AL.pin()
      t.eq(hs.settings.get(settingsKey), nil, "nothing saved for fixed place")
    end,
  },
}
