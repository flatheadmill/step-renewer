# syntax=docker/dockerfile:1.3-labs
FROM ghcr.io/flant/shell-operator:latest
RUN <<EOR
which jo
apk --no-progress update
apk --no-progress add jo zsh step-cli
EOR
ADD hooks/ /hooks/
