# requires: miscell for kill-from-ports

# register the actual configuration

# set-leader l1
# set-leader sopnode-l1
# set-leader sopnode-l1.inria.fr
function set-leader() {
    _leader_defined=true
    local arg="$1"; shift
    grep -q sopnode- <<< $arg || arg="sopnode-${arg}"
    grep -q inria.fr <<< $arg || arg="${arg}.inria.fr"
    export LEADER="$arg"
    echo LEADER=$LEADER
}
function set-worker() {
    _worker_defined=true
    local arg="$1"; shift
    if [[ -n "$arg" ]]; then
        grep -q sopnode- <<< $arg || arg="sopnode-${arg}"
        grep -q inria.fr <<< $arg || arg="${arg}.inria.fr"
    fi
    export WORKER="$arg"
    echo WORKER=$WORKER
}

# use e.g.
# set-fitnode 06 or set-fitnode fit06
# to choose which one is currently available for that test
function set-fitnode() {
    _fitnode_defined=true
    local arg="$1"; shift
    if [[ -n "$arg" ]]; then
        arg=$(sed -e s/fit// <<< $arg)
        arg=$(expr "$arg")
        arg=fit$(printf "%02d" $arg)
    fi
    export FITNODE=$arg
    echo FITNODE=$FITNODE
}

# use e.g.
# set-fitnode 06 or set-fitnode fit06
# to choose which one is currently available for that test
function set-fitnode2() {
    _fitnode2_defined=true
    local arg="$1"; shift
    if [[ -n "$arg" ]]; then
        arg=$(sed -e s/fit// <<< $arg)
        arg=$(expr "$arg")
        arg=fit$(printf "%02d" $arg)
    fi
    export FITNODE2=$arg
    echo FITNODE2=$FITNODE2
}

function check-globals() {
    [[ -z "$_leader_defined" ]] && { echo "use command e.g. 'set-leader l1' to define your LEADER node"; return 1; }
    [[ -z "$_worker_defined" ]] && { echo "use command e.g. 'set-WORKER w1' to define your WORKER node"; return 1; }
    [[ -z "$_fitnode_defined" ]] && { echo "use command e.g. 'set-fitnode 1' to define your FIT node"; return 1; }
    [[ -z "$_fitnode2_defined" ]] && { echo "use command e.g. 'set-fitnode2 2' to define your FIT node #2"; return 1; }
    return 0
}

function all-nodes() {
    echo $LEADER $WORKER $FITNODE $FITNODE2
}

function all-pods() {
    function wired-pod() {
        local wired="$1"; shift
        [[ -z "$wired" ]] && return 0
        local stem=$(sed -e s/sopnode-// -e s/.inria.fr// <<< $wired)
        echo uping-${stem}-pod
    }
    function wireless-pod() {
        local wireless="$1"; shift
        [[ -z "$wireless" ]] && return 0
        echo uping-${wireless}-pod
    }
    echo $(wired-pod $LEADER) $(wired-pod $WORKER) $(wireless-pod $FITNODE) $(wired-pod $FITNODE2)
}


# kick the test pod on each of the 3 nodes
function trash-testpods() {
    local pods=$(kubectl get pod -o yaml | yq ".items[].metadata.name")
    local pod
    for pod in $pods; do
        kubectl delete pod $pod &
    done
    wait
}


# the test pod on the local box
function local-pod() {
    local key=$(hostname | sed -e s/sopnode-// -e 's/\.inria.fr//')
    echo uping-$key-pod
}

# the test pod on the local box
function local-multus-pod() {
    local key=$(hostname | sed -e s/sopnode-// -e 's/\.inria.fr//')
    echo multus-$key-pod
}

function enter-local-pod() {
    local pod=$(local-pod)
    [[ -z "$pod" ]] && { echo could not locate local pod; return 1; }
    kubectl exec -ti $pod -- /bin/bash
}

# find all the pod IPs in the namespace
#function default-namespace-pod-ips() {
#    kubectl get pod -o yaml | \
#        yq '.items[].status.podIP'
#}
# find all the pod names in the namespace
function default-namespace-pod-names() {
    kubectl get pod -o yaml | \
        yq '.items[].metadata.name'
}
function get-pod-ip() {
    local pod="$1"; shift
    kubectl get pod $pod -o yaml | \
        yq '.status.podIP'

}
# find all the pod names+IPs in the namespace
# xxx not ready - can't figure out to
# produce this simply using yq
# function default-namespace-pod-names-ips() {
#     kubectl get pod -o yaml | \
#      yq '.items[].metadata.name'
# }


# from one pod, talk to these 2 hard-wired IP addresses
# that are fixed and should always be reachable
# using curl and host respectively

function -check-api() {
    local source="$1"; shift
    local dests="$@"
    [[ -z "$dests" ]] && dests="10.96.0.1"
    local ok="true"
    local dest="10.96.0.1"

    # using curl on the API endpoint
    local P="====== check-api: FROM $source to $dest (curl) -> "
    command="curl -k --connect-timeout 1 https://$dest:443/"
    exec-in-container-from-podname $source $command >& /dev/null
    [[ $? == 0 ]] && echo $P OK || { echo $P KO; ok=""; success=KO; }
    -log-line check-api $source $dest $success

}
# default
function check-api() { -check-api $(local-pod) "$@"; }


# run ping from one pod to all local pods in the namespace
function -check-pings() {
    local source="$1"; shift
    local dests="$@"
    [[ -z "$dests" ]] && dests=$(default-namespace-pod-names)
    local ok="true"

    local dest
    for dest in $dests; do
        local ip=$(get-pod-ip $dest)
        [[ -z "$ip" ]] && ip=$dest
        local P="====== check-ping: FROM $source to $dest = $ip -> "
        local command="ping -c 1 -w 2 $ip"
        local success=OK
        exec-in-container-from-podname $source $command >& /dev/null
        [[ $? == 0 ]] && echo $P OK || { echo $P KO; ok=""; success=KO; }
        -log-line check-ping $source $dest $success
    done
    [[ -n "$ok" ]] && return 0 || return 1
}
# default
function check-pings() { -check-pings $(local-pod) "$@"; }


# solve DNS names from a pod
# hard-wired defaults for the names
function -check-dnss() {
    local source="$1"; shift
    local names="$@"
    [[ -z "$names" ]] && names="kubernetes r2lab.inria.fr github.com"
    local ok="true"

    local name
    for name in $names; do
        local P="====== check-dns: FROM $source resolving $name -> "
        command="host -W 1 $name"
        local success=OK
        exec-in-container-from-podname $source $command
        [[ $? == 0 ]] && echo $P OK || { echo $P KO; ok=""; success=KO; }
        -log-line check-dns $source $name $success
    done
    [[ -n "$ok" ]] && return 0 || return 1
}
function check-dnss() { -check-dnss $(local-pod) "$@"; }


# open http(s) TCP connections to well-known https services
function -check-https() {
    local source="$1"; shift
    local webs="$@"
    [[ -z "$webs" ]] && webs="r2lab.inria.fr github.com 140.82.121.4"
    local ok="true"

    local web
    for web in $webs; do
        local P="====== check-http: FROM $source opening a HTTP conn to $web:443 -> "
        command="nc -z -v -w 3 $web 443"
        local success=OK
        exec-in-container-from-podname $source $command
        [[ $? == 0 ]] && echo $P OK || { echo $P KO; ok=""; success=KO; }
        -log-line check-http $source $web $success
    done
    [[ -n "$ok" ]] && return 0 || return 1
}
function check-https() { -check-https $(local-pod) "$@"; }


# test kubectl logs
function check-logs() {
    # from the root context this time
    check-globals || return 1
    local pods=$(all-pods)
    local ok="true"

    local pod
    local hostname=$(hostname -s)
    for pod in $pods; do
        local P="====== $hostname: GETTING LOG for $pod -> "
        command="kubectl logs -n default $pod --tail=3"
        echo $command
        local success=OK
        $command
        [[ $? == 0 ]] && echo $P OK || { echo $P KO; ok=""; success=KO; }
        -log-line check-log $hostname $pod $success
    done
    [[ -n "$ok" ]] && return 0 || return 1
}


# test kubectl exec
function check-execs() {
    # from the root context this time
    check-globals || return 1
    local pods=$(all-pods)
    local ok="true"

    local pod
    local hostname=$(hostname -s)
    for pod in $pods; do
        local P="====== $hostname: EXECing in $pod -> "
        command="kubectl exec -n default $pod -- hostname"
        echo $command
        local success=OK
        $command
        [[ $? == 0 ]] && echo $P OK || { echo $P KO; ok=""; success=KO; }
        -log-line check-exec $hostname $pod $success
    done
    [[ -n "$ok" ]] && return 0 || return 1
}

function check-multus() {
    check-globals || return 1
    local hostname=$(hostname -s)
    local pod=$(local-multus-pod)
    local ifname=net1
    local P="====== $hostname: checking for $ifname in $pod -> "
    command="kubectl exec -n default $pod ip add show $ifname"
    echo $command
    local success=OK
    $command
    [[ $? == 0 ]] && echo $P OK || { echo $P KO; ok=""; success=KO; }
    -log-line check-multus $hostname $ifname $success
}

function check-all() {
    check-api &
    check-pings &
    check-dnss &
    check-https &
    check-logs &
    check-execs &
    check-multus &
}


# run one of thoses tests repetitively
# store stats in a file named ~/TESTS.csv
# with a format like this
# DATE;test_function;FROM;TO;SUCCESS
function -log-line() {
    local test_function="$1"; shift
    local from="$1"; shift
    local to="$1"; shift
    local success="$1"; shift

    #local hostname=$(hostname -s)
    local date=$(date "+%Y-%m-%d:%H:%M:%S")

    echo "${test_function};${from};${to};${success};${date}" >> ~/TESTS.csv
}

# run one of thoses tests repetitively
# store stats in a file named ~/TESTS.csv
function -run-n-times() {
    local test_function="$1"; shift
    local count="$1"; shift
    local period="$1"; shift

    local counter=1
    while [[ $counter -le $count ]]; do
        local header="$(hostname -s) $(date +%M:%S)"
        echo "$header $test_function ${counter}/${count}"
        local success=OK
        $test_function || success=KO
        -log-line $test_function $(hostname -s) ALL $success
        sleep $period
        counter=$(($counter +1))
    done
}

# how many time do we try to run all the tests
function run-all() {
    local how_many="$1"; shift
    local period="$1"; shift
    [[ -z "$how_many" ]] && how_many=5
    [[ -z "$period" ]] && period=5
    -run-n-times check-all $how_many $period
}

function log-rpm-versions() {
    local host_l=$(hostname)
    local host_s=$(hostname -s)
    # kube-install sha1
    -log-line version ${host_s} kube-install $(kube-install.sh sha1)
    # RPMS
    local rpm
    for rpm in kubelet kubectl kubeadm cri-o kubernetes-cni; do
        local version=$(rpm -q --queryformat '%{VERSION}' $rpm)
        -log-line version ${host_s} ${rpm} ${version}
    done
    # FEDORA RELEASE
    fedora_version=$(cut -d' ' -f3 < /etc/fedora-release)
    -log-line version ${host_s} fedora $fedora_version
    # CALICO RELEASE
    local calicopod=$(kubectl get pod -n calico-system --field-selector spec.nodeName=${host_l} \
                      | grep calico-node \
                      | awk '{print $1}')
    local calico_version=$(kubectl get pod -n calico-system $calicopod -o yaml \
                           | yq '.spec.containers[0].image' \
                           | cut -d: -f2)
    -log-line version ${host_s} calico ${calico_version}
    # TIGERA RELEASE (all nodes report the same)
    local tigera_version=$(kubectl get pod -n tigera-operator -o yaml \
                           | yq '.items[0].spec.containers[0].image' \
                           | cut -d: -f2)
    -log-line version ${host_s} tigera ${tigera_version}
    # FIT NODES: the rhubarbe image
    if [ -f /etc/rhubarbe-image ]; then
        local rhubarbe=$(tail -1 /etc/rhubarbe-image | cut -d' ' -f 8)
        -log-line version ${host_s} image ${rhubarbe}
    fi
}

function clear-logs() {
    rm -f ~/TESTS.csv
}
