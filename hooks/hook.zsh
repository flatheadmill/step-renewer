#!/usr/bin/env zsh

function quotedoc {
    typeset heredoc spaces=65536 leading='^( +)([^[:space:]])' IFS='' dedented
    typeset -a lines
    while read -r line; do
        lines+=("$line")
        if [[ "$line" =~ $leading && "${#match[1]}" -lt "$spaces" ]]; then
            spaces="${#match[1]}"
        fi
    done
    read -r -d '' dedented < <(printf "%s\n" "${lines[@]}" | sed -E 's/^ {'$spaces'}//')
    eval "$({
        print "cat <<EOF"
        print -Rn "$dedented"
        print "EOF"
    })"
}

function {
    typeset config_map_name
    if [[ ${1:-} = '--config' ]]; then
        quotedoc <<'        EOF'
            configVersion: v1
            schedule:
            - crontab: "* * * * *"
            kubernetes:
            - apiVersion: v1
              kind: ConfigMap
              labelSelector:
                matchLabels:
                  step-renewer.prettyrobots.com: enabled
              executeHookOnEvent: [ "Added" ]
        EOF
    else
        cat "$BINDING_CONTEXT_PATH"
        config_map_name=$(jq -r '.[0].object.metadata.name' $BINDING_CONTEXT_PATH)
        print -- "ConfigMap '${config_map_name}' added"
    fi
} "$@"
