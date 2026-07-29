# Note that the key is never written to this temporary directory, is read with
# process substitution so that the key is never written do disk, at least not
# by the code inside this file. We use a temp directory for the certificate,
# though. The alternative is write process substitution. A temp directory
# makes the code easier to read.

function maybe_renew_certificate {
    # First go through the certificates and determine if any are expiring. If
    # one certificate is expiring, all certificates are renewed. This keeps use
    # from repeating a certificate rollout if we land on whisker where only some
    # of the certificates have reached renewal. While we are doing this we
    # assert that the secret and annotations are formatted correctly.
    typeset certificates=${annotations[step-renewer.flatheadmill.com/pairs]:-tls.crt/tls.key}
    integer expiring=0
    typeset certificate split=()
    for certificate in "${(@As,:,)certificates}"; do
        split=( "${(As:/:)certificate}" )
        (( ${#split} == 2 )) || abend 'bad certificate format %s' $certificates
        typeset crt=$split[1] key=$split[2]
        (( ${+data[$crt]} )) || abend 'certificate missing %s in %s' ${(qqq)crt} ${(qqq)certificates}
        (( ${+data[$key]} )) || abend 'key missing %s in %s' ${(qqq)key} ${(qqq)certificates}
        base64 -d <<< "$data[$crt]" > $tmp/$crt
        if ! expires=$(step certificate inspect --format json $tmp/$crt | jq -r '.validity.end'); then
            print -- "secret=$namespace/$name certificate=$crt message=invalid"
            return
        else
            print -- "secret=$namespace/$name certificate=$crt expires=$expires message=visiting"
        fi
        [[ $STEP_RENEWER_DEBUG = 1 ]] && step certificate inspect $tmp/$crt
        if step certificate needs-renewal --expires-in $o_expires_in $tmp/$crt 2>/dev/null; then
            print -- "secret=$namespace/$name certificate=$crt expires=$expires message=expiring"
            expiring=1
        else
            print -- "secret=$namespace/$name certificate=$crt expires=$expires message=valid"
        fi
    done
    # Do nothing if none of the certificates are expiring. `return 0`, not a bare
    # `return`: the failed `(( expiring ))` set $?=1, and a bare return would
    # propagate it, failing the hook on every valid (nothing-to-do) scan.
    (( expiring )) || return 0
    # Renew all the certificates while building a patch for our secret.
    typeset expirations=() patches=()
    for certificate in "${(@As,:,)certificates}"; do
        split=( "${(As:/:)certificate}" )
        typeset crt=$split[1] key=$split[2]
        if ! step ca renew --force $tmp/$crt <(base64 -d <<< $data[$key]) > /dev/null 2>&1; then
            printf 'unable to renew `%s/%s`.\n' $namespace $name
            return 1
        fi
        expires=$(step certificate inspect --format json $tmp/$crt | jq -r '.validity.end')
        expirations+=( $expires )
        patches+=( $crt=%$tmp/$crt )
        print -- "secret=$namespace/$name certificate=$crt expires=$expires message=renewed"
    done
    # Patch our secret all at once with the new certificates. We use the
    # expiration of our first renewal as the expiration date for the secret.
    kubectl -n $namespace patch secret $name --patch-file =(
        jo data="$(jo "${(@)patches}")" metadata="$(jo annotations="$(jo step-renewer.flatheadmill.com/expires=$expirations[1])")"
    ) > /dev/null
}

function renew_certificates {
    eval "$(args ,secrets ,ca-url ,ca-fingerprint ,expires-in -- "$@")"
    typeset tape=()
    tape=( "${(@QA)${(z)$(
        jq --raw-output '[
            .[] |
            select(.metadata.labels["step-renewer.flatheadmill.com/renewable"] == "") |
            (.metadata.annotations // {}) as $annotations |
            (.data // {}) as $data |
            .metadata.namespace,
            .metadata.name,
            (.metadata.labels | length) * 2,
            (.metadata.labels | to_entries[] | (.key, .value)),
            ($annotations | length) * 2,
            ($annotations | to_entries[] | (.key, .value)),
            ($data | length) * 2,
            ($data | to_entries[] | (.key, .value))
        ] | @sh' < $o_secrets
    )}}" )
    set -- "${(@)tape}"
    typeset -A annotations labels data metadata
    typeset namespace name tmp
    integer count
    tmp=$(mktemp -d) || abend 'cannot create temporary directory'
    {
        STEPPATH=$tmp/step step ca bootstrap --force \
            --ca-url $o_ca_url \
            --fingerprint $o_ca_fingerprint > /dev/null 2>&1 ||
                abend 'unable to bootstrap step'
        while (( $# )); do
            namespace=${1:-} name=${2:-} count=${3:-}
            shift 3
            labels=( "$@[1,$count]" )
            shift $count
            count=${1:-}
            shift
            annotations=( "$@[1,$count]" )
            shift $count
            count=${1:-}
            shift
            data=( "$@[1,$count]" )
            shift $count
            STEPPATH=$tmp/step maybe_renew_certificate
        done
    } always {
        [[ -d $tmp ]] && rm -rf $tmp
    }
}

function process_binding_context {
    [[ -n $STEP_RENEWER_STEP_CA_URL ]] || abend 'STEP_RENEWER_STEP_CA_URL is not set'
    [[ -n $STEP_RENEWER_STEP_CA_FINGERPRINT ]] || abend 'STEP_RENEWER_STEP_CA_FINGERPRINT is not set'
    renew_certificates \
        --ca-url $STEP_RENEWER_STEP_CA_URL \
        --ca-fingerprint $STEP_RENEWER_STEP_CA_FINGERPRINT \
        --expires-in ${STEP_RENEWER_EXPIRES_IN:-50%} \
        --secrets <(jq '[ .[0].snapshots.kubernetes[].object ]' < $BINDING_CONTEXT_PATH)
}
