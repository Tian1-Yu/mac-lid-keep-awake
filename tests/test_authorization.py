"""Validate the prepared-authorization installer against an isolated filesystem."""
import os
import re
import subprocess
import tempfile
from pathlib import Path

project = Path(__file__).resolve().parents[1]
installer = (project / "app/authorization.sh").read_text()
with tempfile.TemporaryDirectory(prefix="lid-authorization-test-") as scratch:
    root = Path(scratch).resolve()
    helper_dir = root / "helpers"
    rules_dir = root / "rules"
    helper_dir.mkdir()
    rules_dir.mkdir()
    uid = "1000"
    helper = helper_dir / f"local.mac-lid-keep-awake-{uid}"
    rule = rules_dir / f"mac_lid_keep_awake_{uid}"

    def make_command(name, script):
        path = root / name
        path.write_text("#!/bin/bash\n" + script)
        path.chmod(0o755)
        return str(path)

    stat = make_command("stat", '''if [[ $2 == '%u' ]]; then printf '0\\n'; else /usr/bin/stat "$@"; fi\n''')
    install = make_command("install", '''[[ "$1 $2 $3 $4" == '-o root -g wheel' ]] || exit 44
shift 4
exec /usr/bin/install "$@"\n''')
    chown = make_command("chown", '''[[ $1 == root:wheel && -f $2 ]]\n''')
    visudo = make_command("visudo", '''if [[ $2 == -f ]]; then exec /usr/sbin/visudo "$@"; fi
if [[ ${FAIL_ACTIVE_RULE-} == 1 ]]; then exit 9; fi
printf '%s: parsed OK\\n' "$TEST_RULE"\n''')
    simulation = (installer.replace("[[ $EUID -eq 0 ]]", "true")
                  .replace("/Library/PrivilegedHelperTools", str(helper_dir))
                  .replace("/private/etc/sudoers.d", str(rules_dir))
                  .replace("/private/tmp/mac-lid-authorization.XXXXXXXX", str(root / "staging.XXXXXXXX"))
                  .replace("/usr/bin/stat", stat).replace("/usr/bin/install", install)
                  .replace("/usr/sbin/chown", chown).replace("/usr/sbin/visudo", visudo))
    env = dict(os.environ, TEST_RULE=str(rule))

    def invoke(*arguments, expected=0, **settings):
        outcome = subprocess.run(
            ["/bin/bash", "-c", simulation, "test", *map(str, arguments)],
            env=dict(env, **settings), text=True, capture_output=True, timeout=12
        )
        assert outcome.returncode == expected, outcome

    original = project / "lid-hold.command"
    invoke("prepare", uid, original)
    assert helper.read_bytes() == original.read_bytes()
    assert helper.stat().st_mode & 0o777 == 0o755
    assert rule.stat().st_mode & 0o777 == 0o440
    rule_text = rule.read_text()
    assert rule_text.startswith(f"#{uid} ALL=(root) NOPASSWD:NOSETENV: sha256:")
    scope = rule_text.split(f" {helper} ", 1)[1].strip()
    for value in ("1", "30", "54", "120", "stop"):
        assert re.fullmatch(scope, value), value
    for value in ("", "0", "05", "121", "-1", "30 stop", "stop;date", "prepare", "revoke"):
        assert not re.fullmatch(scope, value), value
    print("PASS: sudoers grammar, digest pin, user, permissions and exact action scope")

    changed = root / "next-helper"
    changed.write_bytes(original.read_bytes() + b"\n# updated\n")
    invoke("prepare", uid, changed, expected=1, FAIL_ACTIVE_RULE="1")
    assert helper.read_bytes() == original.read_bytes() and rule.read_text() == rule_text
    invoke("revoke", uid, original)
    assert not rule.exists() and not helper.exists()
    invoke("revoke", uid, original)
    print("PASS: failed update restores prior rules; revocation affects only this account")

    invoke("prepare", "0", original, expected=2)
    invoke("start", uid, original, expected=2)
    helper.symlink_to(original)
    invoke("prepare", uid, original, expected=1)
    invoke("revoke", uid, original, expected=1)
    assert helper.is_symlink() and original.is_file()
    print("PASS: invalid users, unknown operations and symlinked targets are rejected")
