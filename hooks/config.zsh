function config {
    jo -p \
        configVersion=v1 \
        schedule="$(jo -a "$(
            jo crontab=${STEP_RENEWER_CRONTAB:-'*/20 * * * *'} \
               group=certificates
        )" )" \
        kubernetes="$(jo -a "$(
            jo \
                apiVersion=v1 \
                kind=Secret \
                labelSelector="$(
                    jo matchLabels="$(
                        jo -- -s 'step-renewer.flatheadmill.com/renewable='
                    )"
                )" \
                executeHookOnEvent='[]' \
                group=certificates
        )" )"
}
