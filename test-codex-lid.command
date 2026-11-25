#!/bin/bash
cd -- "$(dirname -- "$0")" || exit 1
exec /usr/bin/python3 - "$PWD" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

project_dir = Path(sys.argv[1])
output_dir = project_dir / "reports"
output_dir.mkdir(exist_ok=True)
progress_file = output_dir / "progress.json"
hold_tool = project_dir / "lid-hold.command"
report_path = output_dir / ("Codex合盖测试报告-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".md")
bundled_codex = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
configured_codex = os.environ.get("CODEX_BIN")
if configured_codex:
    codex_binary = Path(configured_codex).expanduser().resolve()
elif bundled_codex.is_file():
    codex_binary = bundled_codex
else:
    codex_binary = shutil.which("codex")
hold_state = Path("/private/var/run/local.mac-lid-keep-awake/status")
started_at = time.time()
samples, probes = [], []
tester = None
future = None
armed_at = None
closed_at = None
end_reason = ""
cleanup = ""
timer_status = ""
restored_at_deadline = False
stage = "preflight"


class TestSetupError(Exception):
    pass


def tell(stage_name, message):
    global stage
    stage = stage_name
    print(message, flush=True)
    temp = progress_file.with_suffix(".tmp")
    temp.write_text(json.dumps({"stage": stage_name, "message": message, "report": str(report_path),
                               "at": time.time()}, ensure_ascii=False), encoding="utf-8")
    temp.replace(progress_file)


def shell(*arguments, timeout=4):
    try:
        return subprocess.run(arguments, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def hardware():
    lid = shell("/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "4")
    battery = shell("/usr/sbin/ioreg", "-r", "-c", "AppleSmartBattery", "-w0")
    power = re.search(r'"ExternalConnected" = (Yes|No)\b', battery)
    cover = re.search(r'"AppleClamshellState" = (Yes|No)\b', lid)
    flag = re.search(r"^\s*SleepDisabled\s+([01])\b", shell("/usr/bin/pmset", "-g"), re.M)
    return {
        "at": time.time(),
        "lid": cover.group(1) if cover else "?",
        "external": power.group(1) if power else "?",
        "hold": flag.group(1) if flag else "?",
    }


class AppServer:
    """A separate stdio session using the selected local Codex backend."""

    def __init__(self, cwd):
        self.proc = subprocess.Popen(
            [str(codex_binary), "app-server", "--stdio"],
            cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
        )
        self.buffer = bytearray()
        self.request_id = 0
        try:
            self.request("initialize", {"clientInfo": {"name": "lid_hold_test", "version": "1"}}, 12)
            self.send({"method": "initialized"})
            response = self.request("thread/start", {
                "cwd": cwd, "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": True,
            }, 15)
            self.thread_id = response["thread"]["id"]
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        for stream in (self.proc.stdin, self.proc.stdout):
            stream.close()

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def receive(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.proc.stdout], [], [], remaining)[0]:
                raise TimeoutError
            data = os.read(self.proc.stdout.fileno(), 65536)
            if not data:
                raise EOFError
            self.buffer.extend(data)
        line, rest = self.buffer.split(b"\n", 1)
        self.buffer = bytearray(rest)
        return json.loads(line)

    def request(self, method, params, timeout):
        self.request_id += 1
        request_id = self.request_id
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            message = self.receive(deadline)
            if message.get("id") == request_id and "method" not in message:
                if "error" in message:
                    raise RuntimeError(method)
                return message["result"]
            if "id" in message and "method" in message:
                self.send({"id": message["id"], "error": {"code": -32601, "message": "Unavailable"}})

    def pulse(self, label):
        result = {"label": label, "start": time.time(), "ok": False, "note": "未收到成功响应"}
        marker = "LIDTEST_OK_" + label
        text_fragments = []
        try:
            response = self.request("turn/start", {"threadId": self.thread_id, "input": [{
                "type": "text", "text": "Reply with exactly this text and nothing else: " + marker
            }]}, 12)
            turn_id = response["turn"]["id"]
            deadline = time.monotonic() + 33
            while True:
                message = self.receive(deadline)
                params = message.get("params", {})
                if not isinstance(params, dict) or params.get("threadId") != self.thread_id:
                    continue
                if message.get("method") == "item/completed" and params.get("turnId") == turn_id:
                    item = params.get("item", {})
                    if item.get("type") == "agentMessage":
                        text_fragments.append(item.get("text", ""))
                if message.get("method") == "turn/completed" and params.get("turn", {}).get("id") == turn_id:
                    turn = params["turn"]
                    text_fragments.extend(item.get("text", "") for item in turn.get("items", [])
                                          if item.get("type") == "agentMessage")
                    result["ok"] = turn.get("status") == "completed" and any(
                        part.strip() == marker for part in text_fragments
                    )
                    result["note"] = "完成并收到预期响应" if result["ok"] else "请求完成状态或响应校验未通过"
                    break
        except TimeoutError:
            result["note"] = "请求超时"
        except (EOFError, BrokenPipeError):
            result["note"] = "与 Codex 后台的连接关闭"
        except (RuntimeError, KeyError, ValueError):
            result["note"] = "Codex 后台未正常处理请求"
        result["end"] = time.time()
        return result


def phase_note():
    try:
        return hold_state.read_text().strip()
    except OSError:
        return ""


def short_time(value):
    return datetime.fromtimestamp(value).strftime("%H:%M:%S") if value else "未记录"


def within_closed(probe):
    if not closed_at or probe["start"] < closed_at:
        return False
    before = [sample for sample in samples if sample["at"] <= probe["start"]]
    during = [sample for sample in samples if probe["start"] < sample["at"] <= probe["end"]]
    after = [sample for sample in samples if sample["at"] > probe["end"]]
    if not before or not after:
        return False
    span = [before[-1], *during, after[0]]
    return all(s["lid"] == "Yes" and s["external"] == "No" and s["hold"] == "1" for s in span) and all(
        0 <= second["at"] - first["at"] <= 8 for first, second in zip(span, span[1:])
    )


def sleep_events():
    events = []
    for line in shell("/usr/bin/pmset", "-g", "log", timeout=12).splitlines():
        if "Entering Sleep state" not in line:
            continue
        match = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}).*?due to '([^']+)'", line)
        if match:
            then = datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S %z").timestamp()
            if started_at - 1 <= then <= time.time() + 1:
                reason = re.sub(r"[^A-Za-z0-9 _/-]", "", match.group(2))[:60]
                events.append((then, reason))
    return events


def report():
    closed_probes = [probe for probe in probes if probe["ok"] and within_closed(probe)]
    sleep_log = sleep_events()
    deadline = closed_at + 300 if closed_at is not None else None
    early_sleep = any(
        closed_at is not None and closed_at <= date < deadline - 5 for date, _ in sleep_log
    )
    slept_at_deadline = timer_status.startswith("定时已结束。 已请求立即睡眠。") and any(
        deadline is not None and deadline - 5 <= date <= deadline + 20 for date, _ in sleep_log
    )
    passed = len(closed_probes) >= 2 and not early_sleep
    result = "通过" if passed else "证据不足"
    if early_sleep:
        result = "未通过，保活窗口内出现睡眠"
    elif not passed and any(within_closed(p) and not p["ok"] for p in probes):
        result = "未通过，合盖期间的测试请求失败"
    good_samples = [s for s in samples if s["lid"] == "Yes" and s["external"] == "No" and s["hold"] == "1"]
    active_span = good_samples[-1]["at"] - good_samples[0]["at"] if len(good_samples) >= 2 else 0
    largest_gap = max((b["at"] - a["at"] for a, b in zip(samples, samples[1:])), default=0)
    lines = [
        "# Codex 合盖测试报告", "",
        f"- 合盖期间的 Codex 响应：**{result}**",
        f"- 合盖、无外部供电且保活期间，完整收发成功：{len(closed_probes)} 次",
        f"- 到期恢复睡眠权限：{'已确认' if restored_at_deadline else '未确认'}",
        f"- 到期实际进入睡眠：{'已确认' if slept_at_deadline else '未确认'}",
        f"- 保活工具状态：{timer_status or '未读取到'}",
        f"- 结束原因：{end_reason}",
        f"- 最终睡眠开关：{cleanup}",
        f"- 开始 {short_time(started_at)}，确认保活 {short_time(armed_at)}，首次检测到合盖 {short_time(closed_at)}",
        f"- 符合条件的合盖采样 {len(good_samples)} 次，首末跨度 {active_span:.0f} 秒，最大采样间隔 {largest_gap:.0f} 秒",
        "", "| 请求 | 发出 | 收到/结束 | 结果 | 全程合盖、电池供电且保活 |",
        "|---|---|---|---|---|",
    ]
    for p in probes:
        lines.append(f"| {p['label']} | {short_time(p['start'])} | {short_time(p['end'])} | "
                     f"{p['note']} | {'是' if within_closed(p) else '未确认'} |")
    lines += ["", "## 睡眠记录", ""]
    lines += [f"- {short_time(date)} · {reason}" for date, reason in sleep_log] or ["- 在测试时段内未读取到系统进入睡眠的记录。"]
    lines += ["", "测试用本机 Codex 后台在独立、只读的临时会话中发送了真实模型请求。",
              "结果覆盖本地后台运行与联网响应。桌面窗口点击、已有聊天和持续运行的具体业务任务需另行验证。",
              "报告不含热点名称、IP、账号信息或会话内容。", ""]
    report_path.write_text("\n".join(lines), encoding="utf-8")
    return passed and restored_at_deadline and slept_at_deadline


try:
    tell("checking", "正在核对拔电状态，并做开盖时的 Codex 基准请求。请保持开盖。")
    initial = hardware()
    if initial["external"] != "No" or initial["lid"] != "No":
        raise TestSetupError("开始条件需要开盖并且拔电")
    if initial["hold"] != "0":
        raise TestSetupError("已有保活或睡眠状态不可确认")
    if not codex_binary or not Path(codex_binary).is_file() or not os.access(codex_binary, os.X_OK):
        raise TestSetupError("找不到可运行的 Codex，请安装 Codex 或设置 CODEX_BIN")
    with tempfile.TemporaryDirectory(prefix="codex-lid-test-") as cwd:
        tester = AppServer(cwd)
        baseline = tester.pulse("baseline")
        probes.append(baseline)
        if not baseline["ok"]:
            raise TestSetupError("开盖基准请求失败，未开启保活")
        tell("authorization", "开盖基准请求已成功。请在这个终端窗口输入 Mac 管理员密码。")
        started = subprocess.run([str(hold_tool), "5"], stdin=None).returncode
        confirmed = hardware()
        if started or confirmed["hold"] != "1" or not phase_note().startswith("保活已就绪"):
            raise TestSetupError("系统未确认五分钟保活已就绪")
        armed_at = confirmed["at"]
        samples.append(confirmed)
        tell("ready", "现在可以合盖。保活从合盖开始计时五分钟。请把电脑放在通风桌面上，从合盖起等六分钟再开盖。")
        with ThreadPoolExecutor(max_workers=1) as pool:
            offsets = (0, 35, 80, 155)
            next_probe = 0
            while True:
                sample = hardware()
                now = sample["at"]
                samples.append(sample)
                if future is not None and future.done():
                    probes.append(future.result())
                    future = None
                    if sum(p["ok"] and within_closed(p) for p in probes) >= 2 and stage == "closed":
                        tell("observed", "已收到至少两次合盖期间的 Codex 成功响应，继续等待定时恢复睡眠。")
                if closed_at is None and sample["lid"] == "Yes":
                    closed_at = now
                    tell("closed", "检测到机盖已合上，开始合盖期间的 Codex 请求。")
                if closed_at is not None and sample["lid"] == "No":
                    end_reason = "测试后开盖"
                    break
                if closed_at is None and now - armed_at >= 180:
                    end_reason = "等待合盖超时"
                    break
                if closed_at is not None and now - closed_at >= 380:
                    end_reason = "测试时限已到"
                    break
                if (closed_at is not None and next_probe < len(offsets) and future is None
                        and sample["lid"] == "Yes" and sample["external"] == "No" and sample["hold"] == "1"
                        and now - closed_at >= offsets[next_probe]):
                    next_probe += 1
                    future = pool.submit(tester.pulse, "closed-" + str(next_probe))
                time.sleep(2)
            if future is not None:
                probes.append(future.result())
                samples.append(hardware())
except KeyboardInterrupt:
    end_reason = "测试被手动中止"
except TestSetupError as error:
    end_reason = str(error)
except (RuntimeError, TimeoutError, EOFError, OSError, ValueError, KeyError):
    end_reason = "无法启动或继续测试，请检查本机 Codex 和终端"
finally:
    if tester is not None:
        tester.close()
    final_sample = hardware()
    if armed_at is not None:
        if final_sample["hold"] == "0":
            for _ in range(5):
                timer_status = phase_note()
                if timer_status.startswith("定时已结束") and "正在请求" not in timer_status:
                    break
                time.sleep(0.5)
            restored_at_deadline = timer_status.startswith("定时已结束")
        elif final_sample["hold"] == "1":
            tell("stopping", "正在结束本次测试保活。系统如提示密码，请在终端输入。")
            subprocess.run([str(hold_tool), "stop"], stdin=None)
            final_sample = hardware()
            timer_status = phase_note()
    cleanup = {"0": "已允许系统睡眠", "1": "系统睡眠仍被关闭", "?": "无法核实"}.get(final_sample["hold"])
    if not end_reason:
        end_reason = "测试结束"
    test_passed = report()
    tell("done", "报告已生成：" + str(report_path))
    sys.exit(0 if test_passed else 1)
PY
