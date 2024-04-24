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
    typeset name=${1:-} namespace=${2:-} tmp expires pairs
    shift 2
    tmp=$(mktemp -d) || abend 'cannot create temporary directory'
    {
        while (( $# )); do
            encoding=${1:-} crt_name=${2:-} crt=${3:-} key=${4:-}
            shift 5
            base64 -d <<< "$key" > "$tmp/temp.key"
            base64 -d <<< "$crt" > "$tmp/temp.crt"
            [[ $STEP_RENEWER_DEBUG = 1 ]] && step certificate inspect "$tmp/temp.crt"
            expires=$(step certificate inspect --format json "$tmp/temp.crt" | jq -r '.validity.end')
            if step certificate needs-renewal --expires-in "$STEP_RENEWER_EXPIRES_IN" "$tmp/temp.crt" 2>/dev/null; then
                print -- "secret=$namespace/$name expires=$expires status=renewing"
                step certificate fingerprint "$tmp/temp.crt"
                step ca renew --force "$tmp/temp.crt" "$tmp/temp.key" || abend 'unable to renew `%s/%s`.' $namespace $name
                expires=$(step certificate inspect --format json "$tmp/temp.crt" | jq -r '.validity.end')
                print -- "secret=$namespace/$name expires=$expires status=renewed"
                jo data="$(jo $crt_name=@<(base64 -w 0 < $tmp/temp.crt))" > $tmp/patch.json
                cat "$tmp/patch.json"
                kubectl -n $namespace patch secret $name --patch-file "$tmp/patch.json" > /dev/null
            else
                print -- "secret=$namespace/$name expires=$expires status=okay"
            fi
        done
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
    set -- "${(@QA)${(z)$(
        jq -r '
        [
            .[0].snapshots.kubernetes[] |
            .object as $root |
            [[
                if (.object.metadata.annotations | has("flatheadmill.github.io/pairs"))
                then .object.metadata.annotations["flatheadmill.github.io/pairs"]
                else "tls.crt/tls.key/pem" end |
                    split(":")[] |
                    split("/") | {
                        crt: (if (. | length) > 1 then .[0] else "" end),
                        key: (if (. | length) > 2 then .[1] else "" end),
                        type: (if (. | length) == 3 then .[2] else "pem" end)
                    }
            ][] | (
                .type,
                .crt,
                (.crt as $crt | if (.crt != "" and $root.data | has($crt)) then $root.data[.crt] else "" end),
                (.key as $key | if (.key != "" and $root.data | has($key)) then $root.data[.key] else "" end)
            )] as $certficates |
            (
                .object.metadata.name,
                .object.metadata.namespace,
                $certficates | length,
                $certficates[]
            )
        ] | flatten | @sh' < $process_binding
    )}}"
    typeset name namespace count certificates=()
    while $(( #@ )); do
        name=${1:-} namespace=${2:-} count=${3:-}
        shift 3
        certificates=( "${@[1,$count]}" )
        shift $count
        maybe_renew_certificates $name $namespace "${(@)certificates}"
    done
}
