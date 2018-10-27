#!/bin/bash
#
# NAME
#
#   btrbk-check.sh - check latest btrbk snapshot/backup pairs
#
#
# DESCRIPTION
#
#   Compare files and attributes by checksum, using rsync(1) with
#   options: -i -n -c -a --delete --numeric-ids -H -A -X
#
#   WARNING: Depending on your hardware, this may eat all your CPU
#   power and use high bandwidth! Consider nice(1), ionice(1).
#
#
# SYNOPSIS
#
#   btrbk-check.sh <options> <btrbk-options> [btrbk-filter...]
#
#
# EXAMPLES
#
#   btrbk-check.sh -p /mnt/btr_pool 2> /tmp/rsync_fail.log
#
#     Check latest backups matching the "/mnt/btr_pool filter
#     (see btrbk(1), FILTER STATEMENTS).
#
#   btrbk-check.sh -n -v -v
#
#     Print detailed log as well as command executed by this script,
#     without actually executing rsync commands (-n, --dry-run).
#
#   btrbk-check.sh --all
#
#     Check ALL backups from targets in /etc/btrbk/btrbk.conf.
#     NOTE: This really re-checks ALL files FOR EACH BACKUP!
#
#   btrbk-check.sh --ssh-identity /etc/btrbk/ssh/id_ed25519
#
#     Use "ssh -i /etc/btrbk/ssh/id_ed25519 -l root" for rsync rsh
#     (see btrbk.conf(5)).
#
#
# SEE ALSO
#
#   btrbk(1), btrbk.conf(5), nice(1), ionice(1)
#
#
# AUTHOR
#
#   Axel Burri <axel@tty0.ch>
#

set -u
set -e
set -o pipefail

# defaults: ignore dirs and root folder timestamp change (see below)
ignore_dirs=1
ignore_root_folder_timestamp=1
ssh_identity=
ssh_start_agent=

verbose=0
rsync_log=
dryrun=

list_subcommand="latest"
btrbk_args=()
rsync_args=(-i -n -c -a --delete --numeric-ids -H -A -X)

while [[ "$#" -ge 1 ]]; do
    key="$1"
    case $key in
      -n|--dry-run)
          dryrun=1
          ;;
      --all)
          list_subcommand="backups"
          ;;
      --stats)
          rsync_args+=(--info=stats2)
          ;;
      --ssh-agent)
          ssh_start_agent=1
          ;;
      --ssh-identity)
          # use different ssh identity (-i option) for rsync rsh.
          # NOTE: this overrides all btrbk ssh_* options
          ssh_identity="$2"
          shift
          ;;
      --strict)
          ignore_dirs=
          ignore_root_folder_timestamp=
          ;;
      --ignore-acls)
          rsync_args=(${rsync_args[@]/-A})
          rsync_args=(${rsync_args[@]/--acls})
          ;;
      --ignore-xattrs)
          rsync_args=(${rsync_args[@]/-X})
          rsync_args=(${rsync_args[@]/--xattrs})
          ;;
      -v|--verbose)
          verbose=$((verbose+1))
          [[ $verbose -ge 2 ]] && rsync_log=1
          ;;
      -p|--print)
          # print all rsync diffs to stderr
          rsync_log=1
          ;;
      *)
          # all other args are passed to btrbk
          btrbk_args+=("$key")
          ;;
    esac
    shift
done

tlog()
{
    # same output as btrbk transaction log
    local status=$1
    [[ -n $dryrun ]] && [[ "$status" == "starting" ]] && status="dryrun_starting"
    local line="$(date --iso-8601=seconds) check-rsync ${status} ${dest} ${src} - -"
    tlog+="$line\n"
    echo "$line"
}

rsync_log()
{
    # rsync must go to stderr (see count_rsync_diffs)
    [[ -z "$dryrun" ]] && [[ -n "$rsync_log" ]] && echo "$@" 1>&2
    return 0
}

# parse "rsync -i,--itemize-changes" output.
# prints ndiffs to stdout, and detailed log messages to stderr
count_rsync_diffs()
{
    local nn=0
    local rsync_line_match='^(...........) (.*)$'
    local dump_stats=

    # unset IFS: no word splitting, trimming (read literal line)
    while IFS= read -r rsync_line; do
        local postfix_txt=""
        if [[ -n "$dump_stats" ]]; then
            # dump_stats enabled, echo to stderr
            rsync_log "${rsync_line}"
        elif [[ "$rsync_line" == "" ]]; then
            # empty line denotes start of --info=stats, enable dump_stats
            dump_stats=1
            rsync_log "RSYNC dump-stats"
        elif [[ "$rsync_line" =~ $rsync_line_match ]]; then
            rl_flags="${BASH_REMATCH[1]}"
            rl_path="${BASH_REMATCH[2]}"
            if [[ -n "$ignore_root_folder_timestamp" ]] && [[ "$rsync_line" == ".d..t...... ./" ]]; then
                # ignore timestamp on root folder, for some reason this does not match
                postfix_txt=" # IGNORE reason=ignore_root_folder_timestamp"
            elif [[ -n "$ignore_dirs" ]] && [[ "$rl_flags" == "cd+++++++++" ]]; then
                # nested subvolumes appear as new empty directories ("cd+++++++++") in rsync (btrfs bug?)
                postfix_txt=" # IGNORE reason=ignore_dirs"
            else
                nn=$((nn+1))
                postfix_txt=" # DIFF count=$nn"
            fi
            rsync_log "${rsync_line}${postfix_txt}"
        else
            echo "ERROR: parse rsync line (ignored): ${rsync_line}" 1>&2
        fi
    done
    echo $nn
    return 0
}

rsync_rsh()
{
    # btrbk v0.27.0 sets source_rsh="ssh [flags...] ssh_user@ssh_host"
    # this returns "ssh [flags...] -l ssh_user"
    local rsh=$1
    local rsh_match="(.*) ([a-z0-9_-]+)@([a-zA-Z0-9.-]+)$"

    if [[ -z "$rsh" ]]; then
        echo
    elif [[ -n "$ssh_identity" ]]; then
        # rsync really needs root on target
        echo "ssh -q -i $ssh_identity -l root"
    elif [[ $rsh =~ $rsh_match ]]; then
        echo "${BASH_REMATCH[1]} -l ${BASH_REMATCH[2]}"
    else
        echo "ERROR: failed to parse source_rsh: $rsh" 1>&2
        exit 1
    fi
}

kill_ssh_agent()
{
    echo "Stopping SSH agent"
    eval `ssh-agent -k`
}

start_ssh_agent()
{
    if [[ -z "$ssh_identity" ]]; then
        echo "ERROR: no SSH identity specified for agent"
        return
    fi
    echo "Starting SSH agent"
    eval `ssh-agent -s`
    trap kill_ssh_agent EXIT
    ssh-add "$ssh_identity"
}

[[ -n "$ssh_start_agent" ]] && start_ssh_agent

[[ $verbose -ge 1 ]] && echo "Resolving $list_subcommand"

btrbk_cmd=("btrbk" "list" "$list_subcommand" "--format=raw" "${btrbk_args[@]}")
[[ $verbose -ge 2 ]] && echo "### ${btrbk_cmd[@]}"
"${btrbk_cmd[@]}" | {
    exitstatus=0
    tlog=""
    # if rsync_log is set, repeat tlog on exit
    [[ -n "$rsync_log" ]] && trap 'echo -e "\nTRANSACTION LOG\n---------------\n$tlog"' EXIT

    while read -r list_line; do
        [[ $verbose -ge 2 ]] && echo "... [btrbk list]: $list_line"
        eval $list_line
        src="${snapshot_path}"
        dest="${target_path}"
        [[ -n "$source_host" ]] && src="${source_host}:${src}"
        [[ -n "$target_host" ]] && dest="${target_host}:dest}"

        if [[ -n "$snapshot_path" ]] && [[ -n "$target_path" ]]; then
            rsync_cmd=("rsync" "${rsync_args[@]}")
            [[ -n "$source_rsh" ]] && rsync_cmd+=(-e "$(rsync_rsh "$source_rsh")")
            rsync_cmd+=("${src}/" "${dest}/")
            #rsync_cmd=("echo" '........... SHOULD/FAIL/');   # simulate failure
            #rsync_cmd=("echo" 'cd+++++++++ SHOULD/IGNORE/'); # simulate ignored
            if [[ -n "$dryrun" ]]; then
                rsync_cmd=("cat" "/dev/null");
            fi
            tlog "starting"
            rsync_log "RSYNC start $(date --iso-8601=seconds) ${rsync_cmd[@]}"

            # execute rsync command
            set +e
            ndiffs=$("${rsync_cmd[@]}" | count_rsync_diffs)
            rsync_exitstatus=$?
            set -e
            rsync_log "RSYNC end $(date --iso-8601=seconds)"

            if [[ $rsync_exitstatus -ne 0 ]] || [[ -z "$ndiffs" ]]; then
                echo "ERROR: Command execution failed (status=$rsync_exitstatus): ${rsync_cmd[@]}"
                tlog "ERROR"
                exitstatus=1
            elif [[ $ndiffs -gt 0 ]]; then
                tlog "fail"
                exitstatus=1
            else
                [[ $verbose -ge 1 ]] && echo "CHECK PASSED ($ndiffs diffs)"
                tlog "success"
            fi
        elif [[ -z "$snapshot_path" ]]; then
            [[ $verbose -ge 1 ]] && echo "Skipping backup (no correllated snapshot): $dest"
        elif [[ -z "$target_path" ]]; then
            [[ $verbose -ge 1 ]] && echo "Skipping snapshot (no correllated backup): $src"
        fi
    done
    exit $exitstatus
}
