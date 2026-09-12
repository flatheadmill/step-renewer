#!/usr/bin/env zshctl

source ${0:A:h:h}/hooks/step-renewer.zsh

function check {
    typeset description=$1
    shift
    "$@" || { printf 'not ok - %s\n' "$description" >&2; exit 1; }
    printf 'ok - %s\n' "$description"
}

# No CA or Kubernetes requests: the fixtures model public cert state and an
# optimistic Secret patch. Key bytes are deliberately not real private keys.
function step {
    typeset cert_file=${@[-1]} contents
    case "$1 $2" in
    ('ca bootstrap') return 0 ;;
    ('certificate inspect')
        contents=$(< "$cert_file")
        [[ $contents = malformed ]] && return 1
        printf '{"validity":{"end":"2099-01-01T00:00:00Z"}}\n'
        ;;
    ('certificate needs-renewal')
        contents=$(< "$cert_file")
        [[ $4 = 0s ]] && { [[ $contents = expired ]]; return; }
        [[ $contents = due* ]]
        ;;
    ('ca renew')
        cert_file=$4
        [[ $(< "$cert_file") = due-failure ]] && return 1
        printf fresh > "$cert_file"
        ;;
    (*) return 1 ;;
    esac
}

function kubectl {
    (( patch_failure )) && return 1
    typeset patch_file=${@[-1]}
    cp "$patch_file" "$test_tmp/patch-$5.json"
}

function run_renewal {
    renew_certificates --ca-url https://ca.invalid --ca-fingerprint test \
        --expires-in 30% --secrets "$test_tmp/secrets.json"
}

function fixtures {
    jq -n --argjson certificates "$1" '
        $certificates | to_entries | map({
            metadata: {namespace:"certificates", name:("test-" + (.key|tostring)), resourceVersion:"17",
                labels:{"step-renewer.flatheadmill.com/renewable":""},
                annotations:(.value.annotations // {})},
            data:(.value.data | with_entries(.value |= @base64))
        })
    ' > "$test_tmp/secrets.json"
}

function :execute {
    typeset test_tmp=$(mktemp -d)
    integer patch_failure=0
    {
        fixtures '[{"data":{"tls.crt":"fresh","tls.key":"key"}}]'
        check 'a current certificate needs no write' run_renewal
        check 'current certificate was not patched' test ! -e "$test_tmp/patch-test-0.json"

        fixtures '[{"annotations":{"step-renewer.flatheadmill.com/pairs":"https/cert-key:transport/transport-key:admin/admin-key"},"data":{"https":"due","cert-key":"key","transport":"fresh","transport-key":"key","admin":"fresh","admin-key":"key"}}]'
        check 'one due pair renews the whole bundle' run_renewal
        check 'one atomic patch contains three certs and the resource version' \
            jq -e '.metadata.resourceVersion == "17" and (.data|keys) == ["admin","https","transport"] and ([.data[]|@base64d]|unique) == ["fresh"]' "$test_tmp/patch-test-0.json"

        fixtures '[{"data":{"tls.crt":"due","tls.key":"key"}},{"data":{"tls.crt":"fresh","tls.key":"key"}}]'
        patch_failure=1
        run_renewal >/dev/null 2>&1
        check 'a failed Secret patch fails the run even when the last cert is valid' test $? -ne 0
        patch_failure=0

        fixtures '[{"data":{"tls.crt":"due-failure","tls.key":"key"}},{"data":{"tls.crt":"due","tls.key":"key"}}]'
        run_renewal >/dev/null 2>&1
        check 'a CA failure remains retryable' test $? -ne 0
        check 'another Secret still renews after a CA failure' test -e "$test_tmp/patch-test-1.json"

        fixtures '[{"data":{"tls.crt":"malformed","tls.key":"key"}},{"data":{"tls.crt":"expired","tls.key":"key"}},{"data":{"tls.crt":"due"}},{"data":{"tls.crt":"due","tls.key":"key"}}]'
        check 'invalid, expired, and missing-pair Secrets do not abort the scan' run_renewal
        check 'healthy Secret after invalid inputs renewed' test -e "$test_tmp/patch-test-3.json"
    } always {
        rm -rf -- "$test_tmp"
    }
}
