#!/bin/bash -x

CONSUL_ADDR=http://localhost:8500

name=$1
key="service/fubar/leader"

max_sleep=20
ttl="30s"
session_settings="{\"Name\": \"${name}\", \"TTL\": \"${ttl}\", \"Behavior\": \"release\"}"


function log() {
    msg=$1
    echo -e "$msg" >&2
}


function create_session() {
    session=$(curl -XPUT -d "$session_settings" $CONSUL_ADDR/v1/session/create 2>/dev/null | jq -r '.ID' 2>/dev/null)
    rc=$?
    log "new session $session"
    echo $session
    return $?
}


function is_session_valid() {
    session=$1
    result=$(curl $CONSUL_ADDR/v1/session/info/$session 2>/dev/null | jq -r '.[0].ID' 2>/dev/null)
    if [ $? -eq 0 ]; then
    #output=$(curl $CONSUL_ADDR/v1/session/info/$session 2>/dev/null)
    #if [ "$output" != "Missing session" ]; then
        #result=$(echo "$output" | jq -r '.[0].ID')
        if [ "$result" != "null" ]; then
            log "session $session is valid"
            echo $result
	    rc=0
        else
            log "session expired"
            rc=1
        fi
    else
	log "session missing or invalid"
	rc=1
    fi
    return $rc
}


function acquire_lock() {
    result=$(curl -XPUT -d "{\"host\": \"$name\"}" $CONSUL_ADDR/v1/kv/${key}?acquire=$session 2>/dev/null)
    rc=0
    if [ "$result" = "true" ]; then
        log "I am the leader!"
        rc=0
    else
        log "NOT the leader."
	rc=1
    fi
    return $rc
}


function is_election_time() {
    result=$(curl $CONSUL_ADDR/v1/kv/${key} 2>/dev/null | jq -r '.[0].Session, .[0].ModifyIndex')
    #read holder index <<< ${result}
    holder=$(echo $result | awk {'print $1'})
    index=$(echo $result | awk {'print $2'})
    if [ "${holder}" != "null" ]; then
        log "Not election time."
        rc=1
    else
        log "Election time!"
        rc=0
    fi
    echo $index
    return $rc
}

function main() {
   # TODO May want to intro a top level condition in loop -- where leader checks if
   # still in power *before* attempting to acquire power again.
   echo "My name is $name"

    while true; do
        if ! is_session_valid ${session}; then
            session=$(create_session)
	fi
	# election time is for (having a key already) seize power
        acquire_lock $session
	if [ $? -ne 0 ]; then
	    # if I'm not the leader wait for modification index to change
            log "Not leader, waiting for election time."
	    index=$(is_election_time)
	    # TODO add maximum wait time, if session goes away quietly, no one
	    # grabs it again
            curl $CONSUL_ADDR/v1/kv/${key}?index=${index}
	    # remove sleep once blocking query works
	    # sleep $(( $RANDOM % $max_sleep ))	 
        else
            # leader sleeps on the job
	    sleep $(( $RANDOM % $max_sleep ))	 
        fi
    done
}


main $@
