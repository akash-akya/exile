#!/bin/bash

trap -- '' SIGINT SIGTERM SIGTSTP
while true; do
    date +%F_%T
    sleep 1
done
