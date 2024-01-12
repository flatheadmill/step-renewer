#!/usr/bin/env zsh

function abend {
    printf -- "$@" 1>&2
    print -u 2
    exit 1
}

function quotedoc {
    typeset lines=() spaces=65536 leading='^( +)([^[:space:]])' IFS='' dedented match=()
    while read -r line; do
        lines+=("$line")
        if [[ "$line" =~ $leading && "${#match[1]}" -lt "$spaces" ]]; then
            spaces="${#match[1]}"
        fi
    done
    read -r -d '' dedented < <(printf "%s\n" "${lines[@]}" | sed -E 's/^ {'$spaces'}//')
    eval "$({
        print "cat <<EOF"
        printf '%s' "$dedented"
        print EOF
    })"
}

function maybe_renew_certificate {
    typeset name=${1:-} namespace=${2:-} crt=${3:-} key=${4:-}
    typeset tmp=$(mktemp -d) expires
    {
        base64 -d <<< "$key" > "$tmp/temp.key"
        base64 -d <<< "$crt" > "$tmp/temp.crt"
        [[ $STEP_RENEWER_DEBUG = 1 ]] && step certificate inspect "$tmp/temp.crt"
        expires=$(step certificate inspect --format json "$tmp/temp.crt" | jq -r '.validity.end')
        if step certificate needs-renewal --expires-in "$STEP_RENEWER_EXPIRES_IN" "$tmp/temp.crt" 2>/dev/null; then
            print -- "secret=$namespace/$name expires=$expires status=renewing"
            step certificate fingerprint "$tmp/temp.crt"
            step ca renew --force "$tmp/temp.crt" "$tmp/temp.key" 2>/dev/null
            expires=$(step certificate inspect --format json "$tmp/temp.crt" | jq -r '.validity.end')
            print -- "secret=$namespace/$name expires=$expires status=renewed"
            expires=$(step certificate inspect --format json "$tmp/temp.crt" | jq -r '.validity.end')
            quotedoc <<'            EOF' > "$tmp/patch.yaml"
                data:
                    tls.crt: $(base64 < "$tmp/temp.crt")
            EOF
            kubectl -n $namespace patch secret $name --patch-file "$tmp/patch.yaml" > /dev/null
            if [[ -n $STEP_RENEWER_HUP ]]; then
                cat <<< "$STEP_RENEWER_HUP" > "$tmp/hup"
                chmod 755 "$tmp/hup"
                "$tmp/hup" "$namespace/$name"
            fi
        else
            print -- "secret=$namespace/$name expires=$expires status=okay"
        fi
    } always {
        [[ -d "$tmp" ]] && rm -rf "$tmp"
    }
}

function process_binding_context {
    typeset process_binding=${1:-}
    shift
    [[ -n $STEP_RENEWER_STEP_CA_URL ]] || abend 'STEP_RENEWER_STEP_CA_URL is not set'
    [[ -n $STEP_RENEWER_STEP_CA_FINGERPRINT ]] || abend 'STEP_RENEWER_STEP_CA_FINGERPRINT is not set'
    step ca bootstrap --force \
        --ca-url "$STEP_RENEWER_STEP_CA_URL" \
        --fingerprint "$STEP_RENEWER_STEP_CA_FINGERPRINT" > /dev/null 2>&1 || \
            abend 'unable to bootstrap step'
    set -- "${(@QA){$(z)$(
        jq -r '[
            .[0].snapshots.kubernetes[] |
                (.object.metadata.name, .object.metadata.namespace, .object.data["tls.crt"], .object.data["tls.key"])
        ] | @sh' < "$process_binding"
    )}}"
    while (( $# )); do
        maybe_renew_certificate "$@"
        shift 4
    done
}
