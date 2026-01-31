# syntax=docker/dockerfile:1.3-labs
FROM ghcr.io/flant/shell-operator:latest
RUN echo https://zshctl.sh/apk >> /etc/apk/repositories && wget -qO /etc/apk/keys/alan@prettyrobots.com-67eee297.rsa.pub https://zshctl.sh/keys/alan@prettyrobots.com-67eee297.rsa.pub
RUN apk --no-progress update && apk --no-progress upgrade && apk --no-progress add jo zsh step-cli zshctl
ADD hooks/ /hooks/
