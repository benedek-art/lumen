#!/bin/zsh
# duty-cycle a GPU job so the Mac stays usable: run $2 s, pause $3 s, until the job exits
pid=$1; on=${2:-3}; off=${3:-2}
trap 'kill -CONT $pid 2>/dev/null; exit' INT TERM
while kill -0 $pid 2>/dev/null; do
  kill -CONT $pid; sleep $on
  kill -STOP $pid 2>/dev/null; sleep $off
done
