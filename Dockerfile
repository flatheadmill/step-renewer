# syntax=docker/dockerfile:1.3-labs
FROM ghcr.io/flant/shell-operator:latest
# The flant base points apk at a deckhouse.ru mirror that is unreachable outside
# their network; repoint at the upstream Alpine CDN (the version path is
# preserved, so the pinned Alpine release is unchanged).
RUN sed -i 's|http://dev-registry-cse.deckhouse.ru:8082/repository/alpine|https://dl-cdn.alpinelinux.org/alpine|' /etc/apk/repositories \
 && echo https://zshctl.sh/apk >> /etc/apk/repositories \
 && wget -qO /etc/apk/keys/alan@prettyrobots.com-67eee297.rsa.pub https://zshctl.sh/keys/alan@prettyrobots.com-67eee297.rsa.pub
RUN apk --no-progress update && apk --no-progress upgrade && apk --no-progress add jo zsh step-cli zshctl
ADD hooks/ /hooks/
# shell-operator runs every executable in /hooks; `hook` is the entry point, the
# .zsh files are sourced libraries and must not be run.
RUN chmod +x /hooks/hook && chmod -x /hooks/config.zsh /hooks/step-renewer.zsh
