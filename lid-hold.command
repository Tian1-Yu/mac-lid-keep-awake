#!/bin/bash

export LC_ALL=C
state_dir=/private/var/run/local.mac-lid-keep-awake

show_status() {
    if [[ -r "$state_dir/status" ]]; then
        /bin/cat "$state_dir/status"
    else
        printf '当前没有保活记录。\n'
    fi
    local flag
    flag=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2 }')
    case "$flag" in
        0) printf '系统睡眠已允许。\n' ;;
        1) printf '系统睡眠当前被关闭。\n' ;;
        *) printf '无法读取系统睡眠状态。\n' ;;
    esac
}

change_session() {
    local controller
    IFS= read -r -d '' controller <<'CONTROLLER'
set -u -o pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022

state_dir=/private/var/run/local.mac-lid-keep-awake
label=local.mac-lid-keep-awake
service=system/$label
plist=$state_dir/job.plist
action=$1

if [[ -e "$state_dir/pending" ]] && ! /bin/launchctl print "$service" >/dev/null 2>&1; then
    if [[ -e "$state_dir/restore-required" ]]; then
        /usr/bin/pmset -a disablesleep 0 || exit 1
        flag=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2 }') || exit 1
        [[ $flag == 0 ]] || exit 1
    fi
    printf '已清理中断的保活记录。\n' > "$state_dir/status" || exit 1
    /bin/rm -f "$state_dir/restore-required" "$state_dir/pending" || exit 1
fi

if [[ $action == stop ]]; then
    if [[ ! -e "$state_dir/pending" ]]; then
        printf '当前没有本工具开启的保活。\n'
        exit 0
    fi
    : > "$state_dir/stop" || exit 1
else
    case $action in 5|30|60) ;; *) exit 2 ;; esac
    if [[ -e "$state_dir/pending" ]]; then
        printf '已有保活或恢复正在进行。请先查看状态。\n' >&2
        exit 1
    fi
    flag=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2 }') || exit 1
    if [[ $flag != 0 ]]; then
        printf '当前睡眠设置无法确认或已被关闭，未开启保活。\n' >&2
        exit 1
    fi
    if /bin/launchctl print "$service" >/dev/null 2>&1; then
        /bin/launchctl bootout "$service" || exit 1
    fi
    /bin/rm -f "$plist" "$state_dir/stop" || exit 1
    /usr/bin/plutil -create xml1 "$plist" || exit 1
    /usr/bin/plutil -insert Label -string "$label" "$plist" || exit 1
    /usr/bin/plutil -insert RunAtLoad -bool YES "$plist" || exit 1
    /usr/bin/plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "$plist" || exit 1
    /usr/bin/plutil -insert ProgramArguments -array "$plist" || exit 1

    IFS= read -r -d '' worker <<'WORKER'
set -u -o pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022

state_dir=/private/var/run/local.mac-lid-keep-awake
minutes=$1
restore=$state_dir/restore-required

sleep_flag() {
    /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2 }'
}

lid_state() {
    /usr/sbin/ioreg -r -k AppleClamshellState -d 4 | /usr/bin/awk '
        /"AppleClamshellState"[[:space:]]*=/ && ($NF == "Yes" || $NF == "No") {
            count++; state = $NF
        }
        END { if (count == 1) print state; else exit 1 }'
}

report() {
    printf '%s\n' "$1" > "$state_dir/status.new" &&
        /bin/mv -f "$state_dir/status.new" "$state_dir/status"
}

finish() {
    local reason=$1 policy=${2:-allow} lid
    trap '' HUP INT TERM
    if [[ -e $restore ]]; then
        if ! /usr/bin/pmset -a disablesleep 0 || [[ $(sleep_flag) != 0 ]]; then
            report '恢复睡眠失败。系统会重试，请保持开盖并查看状态。'
            exit 1
        fi
        if [[ $policy == sleep-if-closed ]]; then
            lid=$(lid_state) || lid=unknown
            case $lid in
                Yes)
                    report "$reason 睡眠权限已恢复，正在请求立即睡眠。" || exit 1
                    if /usr/bin/pmset sleepnow; then
                        reason="$reason 已请求立即睡眠。"
                    else
                        reason="$reason 睡眠权限已恢复，但立即睡眠请求失败。"
                    fi ;;
                No) reason="$reason 机盖已打开，已恢复睡眠权限。" ;;
                *) reason="$reason 无法确认机盖状态，已恢复睡眠权限。" ;;
            esac
        fi
        /bin/rm -f "$restore" || exit 1
    fi
    report "$reason" || exit 1
    /bin/rm -f "$state_dir/pending" || exit 1
    exit 0
}

check_conditions() {
    if [[ -e "$state_dir/stop" ]]; then
        finish '已手动结束。' sleep-if-closed
    fi

    local battery thermal
    battery=$(/usr/bin/pmset -g batt | /usr/bin/awk '
        /InternalBattery/ && match($0, /[0-9]+%/) {
            print substr($0, RSTART, RLENGTH - 1)
        }') || finish '无法读取电量，已结束保活。' sleep-if-closed
    if [[ ! $battery =~ ^[0-9]{1,3}$ ]]; then
        finish '无法读取电量，已结束保活。' sleep-if-closed
    fi
    if (( 10#$battery <= 20 )); then
        finish '电量已到 20% 或以下，已结束保活。' sleep-if-closed
    fi

    thermal=$(/usr/bin/osascript -l JavaScript \
        -e 'ObjC.import("Foundation"); $.NSProcessInfo.processInfo.thermalState') ||
        finish '无法读取温度状态，已结束保活。' sleep-if-closed
    case $thermal in
        0|1) ;;
        2|3) finish 'macOS 报告热压力过高，已结束保活。' sleep-if-closed ;;
        *) finish '无法读取温度状态，已结束保活。' sleep-if-closed ;;
    esac
}

[[ -e "$state_dir/pending" ]] || exit 0
trap 'finish "保活被中断。" sleep-if-closed' HUP INT TERM
if [[ -e $restore ]]; then
    finish '保活程序曾异常退出。' sleep-if-closed
fi
check_conditions
if [[ $(lid_state) != No ]]; then
    finish '请开盖后再启动保活。'
fi
if [[ $(sleep_flag) != 0 ]]; then
    finish '睡眠已被其他设置关闭，本工具未开启保活。'
fi

# Record ownership before changing the flag so launchd can restore it after a crash.
: > "$restore" || exit 1
if ! /usr/bin/pmset -a disablesleep 1 || [[ $(sleep_flag) != 1 ]]; then
    finish '系统未确认保活，已恢复正常睡眠。'
fi
SECONDS=0
closed_at=-1
next_conditions_check=5
report "保活已就绪。请在 3 分钟内合盖，合盖后计时 ${minutes} 分钟。" ||
    finish '无法记录状态，已恢复睡眠权限。'

while true; do
    if [[ -e "$state_dir/stop" ]] || (( SECONDS >= next_conditions_check )); then
        check_conditions
        next_conditions_check=$(( SECONDS + 5 ))
    fi
    lid=$(lid_state) || lid=unknown
    if (( closed_at < 0 )); then
        if [[ $lid == Yes ]]; then
            closed_at=$SECONDS
            report "已合盖，开始 ${minutes} 分钟保活。" ||
                finish '无法记录状态，已结束保活。' sleep-if-closed
        elif (( SECONDS >= 180 )); then
            finish '等待合盖超时，已恢复睡眠权限。' sleep-if-closed
        fi
    elif [[ $lid == No ]]; then
        finish '已开盖，本次保活结束，已恢复睡眠权限。'
    elif (( SECONDS - closed_at >= minutes * 60 )); then
        finish '定时已结束。' sleep-if-closed
    fi
    /bin/sleep 1
done
WORKER
    index=0
    for argument in /bin/bash -c "$worker" lid-hold-worker "$action"; do
        /usr/bin/plutil -insert "ProgramArguments.$index" -string "$argument" "$plist" || exit 1
        index=$(( index + 1 ))
    done
    /usr/bin/plutil -lint "$plist" >/dev/null || exit 1
    printf '正在启动保活。\n' > "$state_dir/status" || exit 1
    : > "$state_dir/pending" || exit 1
    if ! /bin/launchctl bootstrap system "$plist"; then
        # If launchd accepted the job despite an error, leave rollback to the worker.
        if ! /bin/launchctl print "$service" >/dev/null 2>&1; then
            /bin/rm -f "$state_dir/pending"
            printf '启动失败。\n' > "$state_dir/status"
        fi
        exit 1
    fi
fi

for (( attempt=0; attempt<20; attempt++ )); do
    if [[ ! -e "$state_dir/pending" ]]; then exit 0; fi
    if [[ $action != stop ]] && /usr/bin/grep -Eq '^(保活已就绪|已合盖，开始)' "$state_dir/status"; then
        exit 0
    fi
    /bin/sleep 0.5
done
printf '系统尚未确认操作完成，请保持开盖并查看状态。\n' >&2
exit 1
CONTROLLER

    # Use a root-owned lock; it closes automatically even if this controller is killed.
    /usr/bin/sudo -- /usr/bin/perl -MFcntl=:flock -e '
        my ($dir, $controller, $action) = @ARGV;
        mkdir $dir, 0755 unless -d $dir;
        die "Cannot open state directory\n" unless -d $dir && !-l $dir && (stat($dir))[4] == 0;
        open my $lock, ">>", "$dir/control.lock" or die "Cannot open state lock: $!\n";
        flock($lock, LOCK_EX) or die "Cannot lock state: $!\n";
        system "/bin/bash", "-c", $controller, "lid-hold-controller", $action;
        exit 1 if $? == -1 || ($? & 127);
        exit($? >> 8);
    ' "$state_dir" "$controller" "$1"
}

case ${1-} in
    '')
        show_status
        printf '\n从合盖开始计时，仍合盖时到点请求睡眠。\n1. 保活 5 分钟（桌面测试）\n2. 保活 30 分钟\n3. 保活 1 小时\n4. 提前结束\n其他键退出。\n'
        read -r -p '请选择：' choice || exit 0
        case $choice in
            1) action=5 ;;
            2) action=30 ;;
            3) action=60 ;;
            4) action=stop ;;
            *) exit 0 ;;
        esac ;;
    5|30|60|stop) action=$1 ;;
    status) show_status; exit 0 ;;
    *) printf '用法：%s [5|30|60|stop|status]\n' "$0" >&2; exit 2 ;;
esac

change_session "$action"
result=$?
show_status
exit "$result"
