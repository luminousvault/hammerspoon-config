#!/bin/bash
# Hammerspoon 통합 테스트 실행.
# 필요: hs CLI (init.lua 의 require("hs.ipc") 로 활성화됨)
# 실제 알림이 뜨고 오디오 상태를 잠깐 건드립니다 (끝나면 복원).
set -euo pipefail

if ! command -v hs >/dev/null; then
  echo "error: hs CLI not found (is Hammerspoon running with hs.ipc?)" >&2
  exit 1
fi

hs -c "dofile(hs.configdir .. '/tests/run.lua')"

# 비동기 실행 완료 대기 (최대 60초)
for _ in $(seq 1 60); do
  done=$(hs -c 'print((testRunner and testRunner.done) and "1" or "0")' 2>/dev/null | tail -1)
  [ "${done}" = "1" ] && break
  sleep 1
done

if [ "${done:-0}" != "1" ]; then
  echo "error: tests did not finish within 60s" >&2
  exit 1
fi

report=$(hs -c 'print(testRunner.report())')
echo "${report}"

# fail 이 하나라도 있으면 실패 종료 코드
echo "${report}" | grep -q "| fail 0 |"
