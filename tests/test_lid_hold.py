import os
import plistlib
import subprocess
import tempfile
import time
from pathlib import Path

root_dir = Path(__file__).resolve().parents[1]
source = (root_dir / "lid-hold.command").read_text(encoding="utf-8")
controller = source.split("<<'CONTROLLER'\n", 1)[1].split("\nCONTROLLER", 1)[0]
worker = source.split("<<'WORKER'\n", 1)[1].split("\nWORKER", 1)[0]

with tempfile.TemporaryDirectory(prefix="mac-lid-hold-test-") as tmp:
    root = Path(tmp).resolve()
    def make_command(name, body):
        path = root / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)
        return str(path)

    pmset = make_command("pmset", '''
case $1 in
  -g)
    case ${2-} in
      batt) printf ' -InternalBattery-0 %s%%; discharging\\n' "$(/bin/cat "$TEST_ROOT/battery")";;
      *) printf ' SleepDisabled %s\\n' "$(/bin/cat "$TEST_ROOT/flag")";;
    esac ;;
  -a)
    [[ $2 == disablesleep ]] || exit 31
    [[ $3 != 0 || ! -e "$TEST_ROOT/fail-restore" ]] || exit 32
    printf '%s\\n' "$3" > "$TEST_ROOT/flag" ;;
  sleepnow)
    [[ $(/bin/cat "$TEST_ROOT/flag") == 0 && $(/bin/cat "$TEST_ROOT/lid") == Yes ]] || exit 36
    printf 'sleep\\n' >> "$TEST_ROOT/sleep-requests"
    [[ ! -e "$TEST_ROOT/fail-sleep" ]] || exit 37 ;;
  *) exit 33 ;;
esac
''')
    ioreg = make_command("ioreg", """
printf '  |   "AppleClamshellState" = %s\\n' "$(/bin/cat "$TEST_ROOT/lid")"
""")
    jxa = make_command("osascript", '/bin/cat "$TEST_ROOT/thermal"\n')
    launch = make_command("launchctl", '''
case $1 in
  print) [[ -e "$TEST_ROOT/loaded" ]] ;;
  bootout) /bin/rm -f "$TEST_ROOT/loaded" ;;
  bootstrap)
    : > "$TEST_ROOT/loaded"
    /usr/bin/plutil -extract ProgramArguments.2 raw -o "$TEST_ROOT/launch-worker" "$3" || exit 34
    /bin/bash "$TEST_ROOT/launch-worker" "$(/usr/bin/plutil -extract ProgramArguments.4 raw "$3")" </dev/null >/dev/null 2>&1 & ;;
  *) exit 35 ;;
esac
''')
    def adjust(code):
        return (code.replace('/private/var/run/local.mac-lid-keep-awake', str(root))
                    .replace('/usr/bin/pmset', pmset).replace('/usr/bin/osascript', jxa)
                    .replace('/bin/launchctl', launch).replace('/usr/sbin/ioreg', ioreg)
                    .replace('minutes * 60', '3').replace('SECONDS >= 180', 'SECONDS >= 5'))

    os.environ["TEST_ROOT"] = str(root)
    def write(name, value=""):
        (root / name).write_text(str(value) + "\n")
    def remove(name):
        (root / name).unlink(missing_ok=True)
    def read(name):
        return (root / name).read_text()
    def run(script, action, expected=0):
        result = subprocess.run(
            ["/bin/bash", "-c", adjust(script), "test", action],
            text=True, capture_output=True, timeout=14
        )
        assert result.returncode == expected, result
        return result
    def wait_until_done():
        for _ in range(50):
            if not (root / "pending").exists():
                return
            time.sleep(0.1)
        raise AssertionError("worker did not finish")

    write("flag", 0)
    write("battery", 80)
    write("thermal", 0)
    write("lid", "No")

    for duration in (1, 5, 30, 47, 60, 120):
        remove("sleep-requests")
        run(controller, str(duration))
        job = plistlib.loads((root / "job.plist").read_bytes())
        assert job["KeepAlive"] == {"SuccessfulExit": False}
        assert job["ProgramArguments"] == ["/bin/bash", "-c", adjust(worker) + "\n", "lid-hold-worker", str(duration)]
        assert "保活已就绪" in read("status"), read("status")
        assert read("flag").strip() == "1" and not (root / "sleep-requests").exists()
        write("lid", "Yes")
        wait_until_done()
        assert read("flag").strip() == "0" and "定时已结束。 已请求立即睡眠。" in read("status")
        assert read("sleep-requests").splitlines() == ["sleep"]
        write("lid", "No")
    print("PASS: valid durations, timer and one immediate sleep request while closed")

    remove("sleep-requests")
    run(controller, "5")
    time.sleep(3.2)
    assert read("flag").strip() == "1" and "保活已就绪" in read("status")
    write("lid", "Yes")
    wait_until_done()
    assert read("sleep-requests").splitlines() == ["sleep"]
    print("PASS: duration starts at physical lid close, not at authorization")

    remove("sleep-requests")
    write("lid", "No")
    run(controller, "30")
    write("lid", "Yes")
    for _ in range(30):
        if "已合盖" in read("status"):
            break
        time.sleep(0.1)
    assert "已合盖" in read("status")
    write("lid", "No")
    wait_until_done()
    assert read("flag").strip() == "0" and "已开盖" in read("status")
    assert not (root / "sleep-requests").exists()
    print("PASS: reopening stops the hold without forcing sleep")

    run(controller, "5")
    wait_until_done()
    assert read("flag").strip() == "0" and "等待合盖超时" in read("status")
    assert not (root / "sleep-requests").exists()
    print("PASS: unused arming window expires without forcing sleep")

    run(controller, "30")
    run(controller, "stop")
    assert read("flag").strip() == "0" and "手动结束" in read("status")
    assert not (root / "sleep-requests").exists()
    print("PASS: stop while open")

    write("battery", 20)
    run(controller, "5")
    assert read("flag").strip() == "0" and "电量已到" in read("status")
    write("battery", 80)
    write("thermal", 2)
    run(controller, "5")
    assert read("flag").strip() == "0" and "热压力过高" in read("status")
    write("thermal", 0)
    assert not (root / "sleep-requests").exists()
    print("PASS: low battery and serious thermal pressure")

    write("flag", 1)
    run(controller, "5", expected=1)
    assert read("flag").strip() == "1"
    print("PASS: preserve another tool's active flag on startup")

    write("pending")
    write("restore-required")
    write("fail-restore")
    run(worker, "5", expected=1)
    assert (root / "restore-required").exists() and "恢复睡眠失败" in read("status")
    remove("fail-restore")
    write("lid", "Yes")
    run(worker, "5")
    assert read("flag").strip() == "0" and "异常退出" in read("status")
    assert not (root / "restore-required").exists() and read("sleep-requests").splitlines() == ["sleep"]
    print("PASS: rollback after restart, restore retry, and closed-lid sleep")

    remove("sleep-requests")
    write("pending")
    write("restore-required")
    write("flag", 1)
    write("fail-sleep")
    run(worker, "5")
    assert read("flag").strip() == "0" and "立即睡眠请求失败" in read("status")
    assert read("sleep-requests").splitlines() == ["sleep"]
    print("PASS: sleep request failure is reported without leaving sleep disabled")

    write("pending")
    write("restore-required")
    write("flag", 1)
    remove("loaded")
    run(controller, "stop")
    assert read("flag").strip() == "0" and not (root / "pending").exists()
    print("PASS: recovery when launchd no longer has the job")
