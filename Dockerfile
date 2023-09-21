# syntax=docker/dockerfile:1.3-labs
FROM ghcr.io/flant/shell-operator:latest
RUN <<EOR
apk --no-progress update
apk --no-progress add zsh
EOR
ADD hooks/ /hooks/
