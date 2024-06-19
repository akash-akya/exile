#!/usr/bin/env bash

trap -- '' SIGINT SIGTERM SIGTSTP

echo "ignored signals"

while true; do
    date +%F_%T
    sleep 1
done
