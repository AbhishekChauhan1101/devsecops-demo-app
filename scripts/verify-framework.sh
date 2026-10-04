#!/usr/bin/env bash
# Offline self-check you can run after customizing the framework (no Jenkins needed):
#   bash scripts/verify-framework.sh
# - bash syntax of every script (+ ShellCheck when installed)
# - PowerShell parser check when pwsh is installed
# - obvious hard-coded secrets / placeholders
# - Jenkinsfile bracket balance
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
fail=0
ok()  { printf '  [ok]   %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; fail=1; }

echo "== bash syntax"
for f in scripts/*.sh scripts/lib/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck"
  if shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh; then ok "shellcheck clean"; else bad "shellcheck findings"; fi
fi

if command -v pwsh >/dev/null 2>&1; then
  echo "== PowerShell parser"
  for f in scripts/*.ps1; do
    if pwsh -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$f',[ref]\$null,[ref]\$e); if(\$e){ \$e | Out-String | Write-Host; exit 1 }"; then ok "$f"; else bad "$f"; fi
  done
else
  echo "== PowerShell parser skipped (pwsh not installed)"
fi

echo "== secrets scan"
pattern='(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"'$ ]{8,})'
if grep -rInE --exclude-dir=.git --exclude=verify-framework.sh "$pattern" . | grep -v -E 'CRED_ID|credentialsId|_CRED|example|<|your' ; then
  bad "possible hard-coded secret (see lines above)"
else
  ok "no obvious hard-coded secrets"
fi

echo "== Jenkinsfile"
python3 - <<'PY' || fail=1
import re,sys
s=open('Jenkinsfile').read()
code="".join(s.split("'''")[0::2])
code="\n".join('' if l.strip().startswith('//') else re.sub(r'\s//\s.*$','',l) for l in code.split('\n'))
bad=False
for o,c in ['{}','()','[]']:
    if code.count(o)!=code.count(c): print(f"  [FAIL] unbalanced {o}{c}: {code.count(o)} vs {code.count(c)}"); bad=True
left=re.findall(r"'(?:CHANGE_ME|YOUR_[A-Z_]+)'",s)
print("  [ok]   brackets balanced" if not bad else "")
print(f"  [info] {len(left)} placeholder value(s) still in CFG (expected until you configure the application)")
sys.exit(1 if bad else 0)
PY
exit "$fail"
