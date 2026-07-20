#!/usr/bin/env sh
# Provision git ssh credentials for private repositories. Sourced by
# autopull.sh before any git network operation, so the exported
# GIT_SSH_COMMAND applies to clone and fetch.
#
# GIT_SSH_KEY         private deploy key, raw PEM or base64-encoded
#                     (auto-detected); empty disables the feature
# GIT_SSH_KNOWN_HOSTS optional known_hosts line(s) to pin the host key;
#                     empty means trust-on-first-use (accept-new)
#
# /root/.ssh lives in the container filesystem, not on a volume, so this
# must run on every cron tick to survive container recreation (same
# reasoning as the safe.directory handling in autopull.sh).

if [ -n "$GIT_SSH_KEY" ]; then
    umask 077
    mkdir -p /root/.ssh

    case $GIT_SSH_KEY in
        -----BEGIN*)
            key=$GIT_SSH_KEY
            ;;
        *)
            if ! key=$(printf '%s' "$GIT_SSH_KEY" | base64 -d 2>/dev/null); then
                p 'GIT_SSH_KEY is neither a PEM key nor valid base64' 'red'
                exit 1
            fi
            ;;
    esac

    # Idempotent writes: only touch files when content changed (cron runs
    # every minute; a changed env value after recreate rotates the key)
    write_if_changed() {
        if [ ! -f "$1" ] || [ "$(cat "$1")" != "$2" ]; then
            printf '%s\n' "$2" > "$1"
            chmod 600 "$1"
        fi
    }

    write_if_changed /root/.ssh/id_autopull "$key"

    if [ -n "$GIT_SSH_KNOWN_HOSTS" ]; then
        write_if_changed /root/.ssh/known_hosts_pinned "$GIT_SSH_KNOWN_HOSTS"
        ssh_opts='-o UserKnownHostsFile=/root/.ssh/known_hosts_pinned -o StrictHostKeyChecking=yes'
    else
        # Built-in trust-on-first-use: first contact stores the host key,
        # later mismatches fail hard
        ssh_opts='-o StrictHostKeyChecking=accept-new'
    fi

    export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_autopull $ssh_opts"
fi
