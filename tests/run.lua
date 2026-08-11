--------------------------------------------------------------------------------
-- tests/run.lua
--
-- 통합 테스트 러너. Hammerspoon 런타임 안에서 실행됩니다.
-- 실제 알림이 화면에 뜨고 오디오 상태를 잠깐 건드리므로 (끝나면 복원)
-- 작업 중이 아닐 때 돌리는 것을 권장합니다.
--
-- 실행
--   ./tests/run.sh                                        (터미널, 권장)
--   hs -c "dofile(hs.configdir .. '/tests/run.lua')"      (결과는 콘솔에)
--
-- 테스트 작성 (계약)
--   tests/test_*.lua 파일은 자동 발견되어 실행됩니다. 새 테스트를 추가하려면
--   아래 형태를 반환하는 파일을 만들기만 하면 됩니다 (러너 수정 불필요):
--     return {
--       { name = "테스트 이름", fn = function(t) ... end },
--       ...
--     }
--   fn 안에서 쓸 수 있는 공용 헬퍼:
--     t.sleep(sec)                        비동기 대기 (알림 소멸, 워처 지연 등)
--     t.waitUntil(cond, timeout?, label)  cond() 가 참이 될 때까지 폴링 (기본 2초)
--     t.eq(a, b, label)                   같음 단언
--     t.truthy(v, label)                  참 단언
--     t.skip(reason)                      전제 조건이 안 맞으면 스킵 처리
--------------------------------------------------------------------------------

-- 재진입 가드: 이전 실행이 끝나기 전에 다시 시작하면 두 코루틴이 동시에 돌며
-- 서로 상태를 밟으므로 거부합니다.
if _G.testRunner and not _G.testRunner.done then
  print("tests already running — wait for the current run to finish")
  return
end

local R = { results = {}, done = false, timers = {} }
_G.testRunner = R

--------------------------------------------------------------------------------
-- 코루틴 기반 비동기 헬퍼
--------------------------------------------------------------------------------

local co

local function resume(...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    table.insert(R.results, { name = "(runner)", status = "FAIL", err = tostring(err) })
    R.done = true
  end
end

local H = {}

-- sec 초 대기. 테스트 함수 안에서만 호출 가능 (코루틴 yield)
function H.sleep(sec)
  -- 주의: 타이머 참조를 유지해야 GC 에 수거되지 않습니다
  table.insert(R.timers, hs.timer.doAfter(sec, resume))
  coroutine.yield()
end

function H.eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      label or "eq", tostring(expected), tostring(actual)), 2)
  end
end

function H.truthy(v, label)
  if not v then
    error((label or "truthy") .. ": expected truthy, got " .. tostring(v), 2)
  end
end

function H.skip(reason)
  error("SKIP: " .. (reason or ""), 0)
end

-- cond() 가 참이 될 때까지 0.1초 간격 폴링. 시간 내에 참이 안 되면 실패.
-- 고정 sleep 보다 빠르고, 시스템 반응이 늦는 날에도 플레이크가 적습니다.
function H.waitUntil(cond, timeout, label)
  timeout = timeout or 2
  local waited = 0
  while waited < timeout do
    if cond() then return end
    H.sleep(0.1)
    waited = waited + 0.1
  end
  error((label or "waitUntil") .. ": condition not met within " .. timeout .. "s", 2)
end

--------------------------------------------------------------------------------
-- 테스트 수집: tests/test_*.lua 자동 발견 (파일명 순 실행)
--------------------------------------------------------------------------------

local testDir = hs.configdir .. "/tests"

local suites = {}
for file in hs.fs.dir(testDir) do
  local suite = file:match("^(test_.+)%.lua$")
  if suite then suites[#suites + 1] = suite end
end
table.sort(suites)

local tests = {}
for _, suite in ipairs(suites) do
  local cases = dofile(testDir .. "/" .. suite .. ".lua")
  for _, case in ipairs(cases) do
    case.suite = suite
    table.insert(tests, case)
  end
end

--------------------------------------------------------------------------------
-- 실행 / 리포트
--------------------------------------------------------------------------------

function R.report()
  local pass, fail, skip = 0, 0, 0
  local lines = {}
  for _, r in ipairs(R.results) do
    if     r.status == "PASS" then pass = pass + 1
    elseif r.status == "SKIP" then skip = skip + 1
    else                           fail = fail + 1 end
    lines[#lines + 1] = string.format("[%s] %s%s", r.status, r.name,
      r.err and (" — " .. r.err) or "")
  end
  lines[#lines + 1] = string.format("total %d | pass %d | fail %d | skip %d",
    #R.results, pass, fail, skip)
  return table.concat(lines, "\n")
end

co = coroutine.create(function()
  for _, t in ipairs(tests) do
    local name = t.suite .. "/" .. t.name
    local ok, err = pcall(t.fn, H)
    if ok then
      table.insert(R.results, { name = name, status = "PASS" })
    elseif tostring(err):find("^SKIP:") then
      table.insert(R.results,
        { name = name, status = "SKIP", err = tostring(err):match("^SKIP:%s*(.*)") })
    else
      table.insert(R.results, { name = name, status = "FAIL", err = tostring(err) })
    end
  end
  R.done = true
  print(R.report())
end)

print("running " .. #tests .. " tests...")
resume()
