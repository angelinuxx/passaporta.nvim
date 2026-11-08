#!/usr/bin/env bash
# End-to-end test of the sftp backend against a throwaway atmoz/sftp container.
#
# Requires docker, lftp, ssh, ssh-keyscan and nvim. Uses a unique container name and a random
# free host port, a temporary known_hosts file and a temporary project: nothing else is touched.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="passaporta-it-$$"
TMP="$(mktemp -d)"
KNOWN_HOSTS="$TMP/known_hosts"
PROJECT="$TMP/project"
PASS=0

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

remote_ls() { docker exec "$NAME" ls -1 "/home/test/upload/site$1"; }

# Run one headless Neovim step. STEP selects what the driver does, WAIT is a Lua pattern
# matched against notifications to know the async operation finished.
nvim_step() {
  local hosts="${3:-$KNOWN_HOSTS}"
  STEP="$1" WAIT="$2" KNOWN_HOSTS="$hosts" PROJECT_DIR="$PROJECT" \
    nvim --headless --noplugin -u NONE --cmd "set rtp^=$REPO" --cmd "cd $PROJECT" \
    -c "luafile $TMP/driver.lua" -c "qa!"
}

step "starting atmoz/sftp as $NAME"
docker run -d --name "$NAME" -p 127.0.0.1:0:22 atmoz/sftp test:pass:::upload >/dev/null
PORT="$(docker port "$NAME" 22/tcp | head -n1 | sed 's/.*://')"
[ -n "$PORT" ] || fail "could not read the published port"
echo "port $PORT"

step "waiting for sshd"
ready=0
for _ in $(seq 1 30); do
  if ssh-keyscan -T 2 -p "$PORT" 127.0.0.1 >"$KNOWN_HOSTS" 2>/dev/null && [ -s "$KNOWN_HOSTS" ]; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || fail "sshd did not become ready in 30 s"
ok "sshd ready, host key stored in the temporary known_hosts"

mkdir -p "$PROJECT/.nvim" "$PROJECT/src/sub"
echo one >"$PROJECT/src/a.txt"
echo two >"$PROJECT/src/sub/b.txt"
echo secret >"$PROJECT/src/skip.env"
cat >"$PROJECT/.nvim/deployment.lua" <<LUA
return {
  it = {
    host = "127.0.0.1",
    port = $PORT,
    username = "test",
    protocol = "sftp",
    password = "pass",
    mappings = { { ["local"] = "src", ["remote"] = "/upload/site" } },
    excludedPaths = { "*.env" },
  },
}
LUA

cat >"$TMP/driver.lua" <<'LUA'
local passaporta = require "passaporta"
local messages, failed = {}, false

passaporta.setup {
  notify = function(msg, level)
    messages[#messages + 1] = msg
    if level >= vim.log.levels.WARN then
      failed = true
    end
  end,
  lftp = {
    settings = {
      ["sftp:connect-program"] = "ssh -a -x -o UserKnownHostsFile=" .. vim.env.KNOWN_HOSTS .. " -o StrictHostKeyChecking=yes",
    },
  },
}

local step, wait_for = vim.env.STEP, vim.env.WAIT
local src = vim.env.PROJECT_DIR .. "/src"

if step == "upload" then
  passaporta.upload(src)
elseif step == "diff" then
  passaporta.diff(src)
elseif step == "syncdown" then
  passaporta.syncdown(src)
end

local done = vim.wait(120000, function()
  if failed then
    return true
  end
  for _, m in ipairs(messages) do
    if m:find(wait_for) then
      return true
    end
  end
  return false
end, 100)

io.write(table.concat(messages, "\n") .. "\n")
if not done or failed then
  vim.cmd "cquit 1"
end

if step == "diff" then
  local qf = vim.fn.getqflist()
  io.write("quickfix entries: " .. #qf .. "\n")
  if #qf == 0 then
    vim.cmd "cquit 1"
  end
end
LUA

step "1. upload a directory"
nvim_step upload "uploaded" || fail "upload failed"
remote_ls "" | grep -qx "a.txt" || fail "a.txt missing on the server"
remote_ls "/sub" | grep -qx "b.txt" || fail "sub/b.txt missing on the server"
if remote_ls "" | grep -qx "skip.env"; then fail "skip.env must be excluded"; fi
ok "files uploaded, excluded file left out"

step "2. diff after a local change"
echo changed >>"$PROJECT/src/a.txt"
echo new >"$PROJECT/src/new.txt"
nvim_step diff "differences" || fail "diff failed or the quickfix list is empty"
ok "diff filled the quickfix list"

step "3. syncdown"
docker exec "$NAME" sh -c 'echo remote-only >/home/test/upload/site/remote.txt; chown test /home/test/upload/site/remote.txt'
nvim_step syncdown "synced down" || fail "syncdown failed"
[ -f "$PROJECT/src/remote.txt" ] || fail "remote.txt was not downloaded"
[ ! -e "$PROJECT/src/new.txt" ] || fail "new.txt should have been deleted by syncdown"
[ "$(cat "$PROJECT/src/a.txt")" = one ] || fail "a.txt was not restored"
ok "local state mirrors the server"

step "4. unknown host key must fail fast"
: >"$TMP/empty_known_hosts"
start="$(date +%s)"
if nvim_step upload "uploaded" "$TMP/empty_known_hosts" >"$TMP/unknown.log" 2>&1; then
  fail "upload succeeded with an unknown host key"
fi
elapsed=$(($(date +%s) - start))
[ "$elapsed" -le 30 ] || fail "unknown host key took ${elapsed}s (limit 30 s)"
sed "s/^/     /" "$TMP/unknown.log"
ok "unknown host key rejected in ${elapsed}s"

printf '\n%d checks passed\n' "$PASS"
