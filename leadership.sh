#!/bin/bash

CONSUL_ADDR=http://localhost:8500

name=$1
key="service/fubar/leader"

max_sleep=20
ttl="30s"
session_settings="{\"Name\": \"${name}\", \"TTL\": \"${ttl}\", \"Behavior\": \"release\"}"

# Global state
session=


function log() {
    msg=$1
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") [ ${name} ] ${msg}" >&2
}


function create_session() {
    session=$(curl -XPUT -d "$session_settings" $CONSUL_ADDR/v1/session/create 2>/dev/null | jq -r '.ID' 2>/dev/null)
    rc=$?
    log "new session $session"
    echo $session
    return $?
}

function renew_session() {
    rc=1
    session=$1
    if [ -z ${session} ]; then
        return $rc
    fi
    _=$(curl -XPUT $CONSUL_ADDR/v1/session/renew/${session} 2>/dev/null | jq -r '.[0].ID' 2>/dev/null)
    jq_exit=$?
    if [ $jq_exit -eq 0 ]; then
        log "session $session renewed"
        rc=0
    else
        log "WARNING $session terminated before renewal!"
        rc=1
    fi
    return $rc
}


function is_session_valid() {
    rc=1
    session=$1
    if [ -z ${session} ]; then
        return $rc
    fi
    result=$(curl $CONSUL_ADDR/v1/session/info/$session 2>/dev/null | jq -r '.[0].ID' 2>/dev/null)
    jq_exit=$?
    if [ $jq_exit -eq 0 ]; then
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


function acquire_leadership() {
    rc=1
    result=$(curl -XPUT -d "{\"host\": \"$name\"}" $CONSUL_ADDR/v1/kv/${key}?acquire=$session 2>/dev/null)
    if [ "$result" = "true" ]; then
        log "I am the leader!"
        rc=0
    else
        log "NOT the leader."
        rc=1
    fi
    return $rc
}


function win_leadership_struggle() {
    rc=1
    current_session=$(curl $CONSUL_ADDR/v1/kv/${key} 2>/dev/null | jq -r '.[0].Session' 2> /dev/null)
    jq_exit=$?
    if [ $jq_exit -eq 0 ]; then
        if [ "${session}" = "${current_session}" ]; then
            already_leader=1
            log "Already am the leader."
            rc=0
        else
            acquire_leadership $session
            rc=$?    
        fi
    fi
    return $rc
}


function get_election_time() {
    index=$(curl $CONSUL_ADDR/v1/kv/${key} 2>/dev/null | jq -r '.[0].ModifyIndex')
    echo $index
    return $rc
}

function main() {
    echo "My name is $name"

    while true; do
        max_wait=$(( $RANDOM % $max_sleep ))
        if ! is_session_valid ${session}; then
            session=$(create_session)
        else
            # branch hit by leader after sleep -- if session is still valid
	    # very likely still in power with existing session.
	    # or by non-leaders that just lost an election but are within
	    # session TTL
            if ! renew_session ${session}; then
                # hit race between checking for valid session and it expiring
		# right after, start loop over again.
		continue
            fi
        fi
        if ! win_leadership_struggle ${session}; then
            # if I'm not the leader wait for modification index to change
	    log "Not leader, waiting for election time (max: $max_wait seconds)."
            index=$(get_election_time)
            curl --max-time $max_wait $CONSUL_ADDR/v1/kv/${key}?index=${index}
        else
            # leader sleeps on the job
	    log "Leader napping for $max_wait seconds."
            sleep $max_wait
        fi
    done
}


main $@
