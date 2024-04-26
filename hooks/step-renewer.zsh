#!/usr/bin/env zsh

function abend {
    printf -- "$@" 1>&2
    print -u 2
    exit 1
}

# Note that the key is never written to this temporary directory, is read with
# process substitution so that the key is never written do disk, at least not
# by the code inside this project. We use a temp directory for the
# certificate, though. The alternative is write process substitution. A temp
# directory make the code easier to read.

function maybe_renew_certificate {
    typeset tmp=${1:-} name=${2:-} namespace=${3:-} expires
    shift 3
    while (( $# )); do
        encoding=${1:-} crt_name=${2:-} crt=${3:-} key=${4:-}
        shift 4
        base64 -d <<< "$crt" > $tmp/temp.crt
        expires=$(step certificate inspect --format json $tmp/temp.crt | jq -r '.validity.end')
        if ! expires=$(step certificate inspect --format json $tmp/temp.crt | jq -r '.validity.end'); then
            print -- "secret=$namespace/$name certificate=$crt_name encoding=$encoding status=invalid"
            continue
        else
            print -- "secret=$namespace/$name certificate=$crt_name encoding=$encoding expires=$expires status=visiting"
        fi
        [[ $STEP_RENEWER_DEBUG = 1 ]] && step certificate inspect $tmp/temp.crt
        if step certificate needs-renewal --expires-in $STEP_RENEWER_EXPIRES_IN $tmp/temp.crt 2>/dev/null; then
            if ! step ca renew --force $tmp/temp.crt <(base64 -d <<< $key); then
                printf 'unable to renew `%s/%s`.\n' $namespace $name
                continue
            fi
            expires=$(step certificate inspect --format json $tmp/temp.crt | jq -r '.validity.end')
            kubectl -n $namespace patch secret $name --patch-file =(jo data="$(jo $crt_name=%$tmp/temp.crt)") > /dev/null
            print -- "secret=$namespace/$name certificate=$crt_name encoding=$encoding expires=$expires status=renewed"
        else
            print -- "secret=$namespace/$name certificate=$crt_name encoding=$encoding expires=$expires status=okay"
        fi
    done
}

function renew_certificates {
    [[ -n $STEP_RENEWER_STEP_CA_URL ]] || abend 'STEP_RENEWER_STEP_CA_URL is not set'
    [[ -n $STEP_RENEWER_STEP_CA_FINGERPRINT ]] || abend 'STEP_RENEWER_STEP_CA_FINGERPRINT is not set'
    typeset input=${1:-} tmp name count certificates=()
    set -- "${(QA@)${(z)$(jq -r '
        [
            .[] |
            select(.metadata.labels["flatheadmill.github.io"] == "step-renewer") |
            . as $root |
            [[
                if (.metadata.annotations | has("flatheadmill.github.io/step-renewer.pairs"))
                then .metadata.annotations["flatheadmill.github.io/step-renewer.pairs"]
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
                (.crt as $crt | if ($root.data | has($crt)) then $root.data[.crt] else "" end),
                (.key as $key | if ($root.data | has($key)) then $root.data[.key] else "" end)
            )] as $certficates |
            (.metadata.name, .metadata.namespace, ($certficates | length), $certficates[])
        ] | @sh
    ' < $input)}}"
    tmp=$(mktemp -d) || abend 'cannot create temporary directory'
    {
        STEPPATH=$tmp/step step ca bootstrap --force \
            --ca-url "$STEP_RENEWER_STEP_CA_URL" \
            --fingerprint "$STEP_RENEWER_STEP_CA_FINGERPRINT" > /dev/null 2>&1 || \
                abend 'unable to bootstrap step'
        while (( $# )); do
            name=${1:-} namespace=${2:-} count=${3:-}
            shift 3
            certificates=( "$@[1,$count]" )
            shift $count
            STEPPATH=$tmp/step maybe_renew_certificate $tmp $name $namespace "${(@)certificates}"
        done
    } always {
        [[ -d $tmp ]] && rm -rf $tmp
    }
}

function process_binding_context {
    typeset process_binding=${1:-}
    shift
    renew_certificates  <(jq '[ .[0].snapshots.kubernetes[] | .object ]' < $process_binding)
}
