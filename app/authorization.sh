#!/bin/bash
set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

operation=${1-}
uid=${2-}
source=${3-}
[[ $EUID -eq 0 ]] || exit 1
[[ "$uid" =~ ^[1-9][0-9]{0,9}$ ]] || exit 2
[[ "$operation" == prepare || "$operation" == revoke ]] || exit 2

helper_dir=/Library/PrivilegedHelperTools
rules_dir=/private/etc/sudoers.d
helper="$helper_dir/local.mac-lid-keep-awake-$uid"
rule="$rules_dir/mac_lid_keep_awake_$uid"
for directory in "$helper_dir" "$rules_dir"; do
    [[ -d "$directory" && ! -L "$directory" ]] || exit 1
    [[ $(/usr/bin/stat -f '%u' "$directory") == 0 ]] || exit 1
    mode=$(/usr/bin/stat -f '%Lp' "$directory")
    (( (8#$mode & 0022) == 0 )) || exit 1
done
for path in "$helper" "$rule"; do
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" && $(/usr/bin/stat -f '%u' "$path") == 0 ]] || exit 1
    fi
done

if [[ "$operation" == revoke ]]; then
    /bin/rm -f "$rule" "$helper"
    exit 0
fi

[[ -f "$source" && ! -L "$source" ]] || exit 1
temp_dir=$(/usr/bin/mktemp -d /private/tmp/mac-lid-authorization.XXXXXXXX)
staged_helper=
staged_rule=
cleanup() {
    [[ -z $staged_helper ]] || /bin/rm -f "$staged_helper"
    [[ -z $staged_rule ]] || /bin/rm -f "$staged_rule"
    /bin/rm -f "$temp_dir/helper" "$temp_dir/rule"
    /bin/rmdir "$temp_dir"
}
trap cleanup EXIT
staged_helper=$(/usr/bin/mktemp "$helper_dir/.mac-lid-helper.XXXXXXXX")
staged_rule=$(/usr/bin/mktemp "$rules_dir/.mac-lid-rule.XXXXXXXX")
[[ ! -e "$helper" ]] || /bin/cp -p "$helper" "$temp_dir/helper"
[[ ! -e "$rule" ]] || /bin/cp -p "$rule" "$temp_dir/rule"
/usr/bin/install -o root -g wheel -m 0755 "$source" "$staged_helper"
/bin/bash -n "$staged_helper"
digest=$(/usr/bin/shasum -a 256 "$staged_helper" | /usr/bin/awk '{print $1}')
[[ "$digest" =~ ^[a-f0-9]{64}$ ]] || exit 1
# Match a single allowed duration or stop, with no extra arguments.
printf '#%s ALL=(root) NOPASSWD:NOSETENV: sha256:%s %s ^(stop|[1-9]|[1-9][0-9]|1[01][0-9]|120)$\n' \
    "$uid" "$digest" "$helper" > "$staged_rule"
/usr/sbin/chown root:wheel "$staged_rule"
/bin/chmod 0440 "$staged_rule"
/usr/sbin/visudo -c -f "$staged_rule" >/dev/null

/bin/mv -f "$staged_helper" "$helper"
if ! /bin/mv -f "$staged_rule" "$rule" ||
    ! /usr/sbin/visudo -c | /usr/bin/grep -F "$(/usr/bin/basename "$rule"): parsed OK" >/dev/null; then
    /bin/rm -f "$rule" "$helper"
    [[ ! -e "$temp_dir/helper" ]] || /bin/mv "$temp_dir/helper" "$helper"
    [[ ! -e "$temp_dir/rule" ]] || /bin/mv "$temp_dir/rule" "$rule"
    exit 1
fi
