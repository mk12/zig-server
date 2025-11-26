#!/bin/bash

set -eufo pipefail

exe=zig-out/bin/zigserver

usage() {
    cat <<EOF
Usage: $0 PORT MODE SLEEP N M

* Runs $exe PORT MODE SLEEP (N * M)
* Server sleeps for SLEEP s in every request handler
* We send N batches of M simultaneous requests
* Once the whole batch is serviced we do the next
* We continously log the server RSS in KiB
* DebugAllocator checks leaks at the end
EOF
}

if [[ $# -ne 5 ]]; then
    usage >&2
    exit 1
fi

port=$1
mode=$2
sleep=$3
num_batches=$4
batch_size=$5

limit=$(( num_batches * batch_size + 1 ))

if ! [[ -x "$exe" ]]; then
    echo >&2 "$exe not found, did you zig build?"
    exit 1
fi

pids=()
trap 'kill "${pids[@]}" &> /dev/null || :' EXIT

echo "Starting server: port = $port, mode = $mode, sleep = ${sleep}s, limit = $limit"
"$exe" "$port" "$mode" "$sleep" "$limit" & pids+=($!)

echo "Monitoring RSS"
( while :; do echo "RSS =$(ps -o rss= -p "${pids[0]}")"; sleep 1; done ) & pids+=($!)

echo "Waiting a second for the server to start up"
sleep 1

echo "Sending $num_batches batches of $batch_size requests"
i=1
while [[ "$i" -le "$num_batches" ]]; do
    echo "Batch [$i/$num_batches]"
    (
        j=1
        while [[ "$j" -le "$batch_size" ]]; do
            nc localhost "$port" <<< "hi" >/dev/null &
            (( j++ )) || :
        done
        wait
    )
    (( i++ )) || :
done

echo "All batches finished. Press enter to stop the server."
read
nc localhost "$port" <<< ""

echo "Killing RSS monitor"
disown "${pids[1]}"
kill "${pids[1]}"

echo "Waiting for server to shut down and check for leaks."
wait
