--------------------------------------------------------------------------------
-- local_config.example.lua
--
-- 이 파일을 local_config.lua 로 복사한 뒤 자신의 환경에 맞게 수정하세요.
--   cp local_config.example.lua local_config.lua
-- local_config.lua 는 .gitignore 에 등록되어 커밋되지 않습니다.
--
-- 최상위 키는 기능(모듈)별 네임스페이스입니다. 사용하지 않는 기능의 키는
-- 지우거나 비워 둬도 됩니다 — 해당 모듈만 비활성 상태로 동작합니다.
--   places : modules/audio_by_location.lua 에서 사용
--------------------------------------------------------------------------------

return {
  -- 장소 정의 (audio_by_location 에서 사용)
  -- 장소 id(키)와 개수는 자유롭게 정하세요. 각 장소에 지정 가능한 정책:
  --   ssids         : 이 장소로 인식할 SSID 목록
  --   fallback      : true 면 등록되지 않은 SSID 에 연결됐을 때 이 장소로
  --                   간주 (하나만 정의. 유선/미연결은 여전히 장소 없음)
  --   name          : 알림에 표시할 이름 (생략 시 장소 id)
  --   audio         : 기본 오디오 상태 { muted, volume }
  --   remember      : true 면 떠날 때 상태를 기억해두고 돌아오면 복원
  --                   (이때 audio 는 저장값이 아직 없을 때만 쓰는 초기 기본값)
  --   speakerOnly   : true 면 스피커류에만 적용 (이어폰 등 개인 기기 제외)
  --   enforceOnWake : true 면 절전 복귀 시 강제 재적용
  places = {
    office = {
      ssids = { "MyOfficeWifi" },
      name  = "회사",
      audio = { muted = true },
      remember = false,
      speakerOnly   = true,
      enforceOnWake = true,
    },
    home = {
      ssids = { "MyHomeWifi", "MyHomeWifi_5G" },
      name  = "집",
      audio = { muted = false, volume = 50 },
      remember = true,
    },
    -- 필요한 만큼 추가:
    -- cafe = {
    --   ssids = { "StarbucksWifi" },
    --   name  = "카페",
    --   audio = { muted = true },
    --   speakerOnly = true,
    -- },
    -- 등록되지 않은 SSID 대비 (공공장소 등에서 소리가 나지 않게):
    -- outside = {
    --   fallback = true,
    --   name  = "외부",
    --   audio = { muted = true },
    --   speakerOnly   = true,
    --   enforceOnWake = true,
    -- },
  },
}
