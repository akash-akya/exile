#!/bin/bash

trap -- '' SIGINT SIGTERM SIGTSTP

echo "ignored signals"

while true; do
    sleep 1
    date +%F_%T
done
