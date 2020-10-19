#! /bin/bash
#
# Deploy docker stack
#

# Images
SNAKEMAKE_IMAGE=quay.io/biocontainers/snakemake-minimal:5.26.1--py_1
SLURM_IMAGE=giovtorres/docker-centos7-slurm:latest

docker pull -q $SNAKEMAKE_IMAGE
docker pull -q $SLURM_IMAGE

# Stack and service config
STACK_NAME=cookiecutter-slurm
SLURM_SERVICE=${STACK_NAME}_slurm
SNAKEMAKE_SERVICE=${STACK_NAME}_snakemake
LOCAL_USER_ID=$(id -u)


##############################
## Functions
##############################
## Add slurm user to container
function add_slurm_user {
    user=$1
    container=$2
    # check if user exists
    docker exec $container /bin/bash -c "id $user" > /dev/null
    if [ $? -eq 1 ]; then
	echo "Adding user $user to docker container"
	docker exec $container /bin/bash -c "useradd --shell /bin/bash -u $user -o -c \"\" -m -g slurm user"
	if [ $? -eq 1 ]; then
	    echo "Failed to add user $user"
	    exit 1;
	fi
    fi
}


SLURM_CONF=$(cat <<EOF
# NEW COMPUTE NODE DEFINITIONS
NodeName=DEFAULT Sockets=1 CoresPerSocket=2 ThreadsPerCore=2 State=UNKNOWN TmpDisk=10000
NodeName=c[1-2] NodeHostName=localhost NodeAddr=127.0.0.1 RealMemory=500 Feature=thin,mem500MB
NodeName=c[3-4] NodeHostName=localhost NodeAddr=127.0.0.1 RealMemory=800 Feature=fat,mem800MB
NodeName=c[5] NodeHostName=localhost NodeAddr=127.0.0.1 RealMemory=500 Feature=thin,mem500MB
# NEW PARTITIONS
PartitionName=normal Default=YES Nodes=c[1-4] Shared=NO MaxNodes=1 MaxTime=5-00:00:00 DefaultTime=5-00:00:00 State=UP DefMemPerCPU=500 OverSubscribe=NO
PartitionName=debug  Nodes=c[5] Shared=NO MaxNodes=1 MaxTime=05:00:00 DefaultTime=05:00:00 State=UP DefMemPerCPU=500
EOF
	  )


function modify_slurm_conf {
    container=$1
    slurmconf=/etc/slurm/slurm.conf

    docker exec $container /bin/bash -c "cat $slurmconf" | grep "NEW COMPUTE NODE DEFINITIONS"
    if [ $? -eq 1 ]; then
	echo "Rewriting /etc/slurm/slurm.conf"
        # docker exec $container /bin/bash -c 'sacctmgr --immediate add cluster name=linux'
	# Change consumable resources to Core; Setting CR_Core_Memory fails for some reason
        # docker exec $container /bin/bash -c "sed -i -e \"s/CR_CPU_Memory/CR_Core/g\" $slurmconf ;"
	# Comment out node names and partition names that are to be redefined
	docker exec $container /bin/bash -c "sed -i -e \"s/^GresTypes/# GresTypes/g\" $slurmconf ;"
        docker exec $container /bin/bash -c "sed -i -e \"s/^NodeName/# NodeName/g\" $slurmconf ;"
        docker exec $container /bin/bash -c "sed -i -e \"s/^PartitionName/# PartitionName/g\" $slurmconf ;"
	echo "  setting up slurm partitions..."
        docker exec $container /bin/bash -c "echo \"$SLURM_CONF\" >> $slurmconf ; "
	# Restart services
	echo "  restarting slurm services..."
	docker exec $container supervisorctl restart slurmdbd
	docker exec $container supervisorctl restart slurmctld
	docker exec $container /bin/bash -c 'sacctmgr --immediate add cluster name=linux'
        docker exec $container /bin/bash -c "sacctmgr --immediate add account none,test Cluster=linux Description=\"none\" Organization=\"none\""
    fi
}


### Check if service is up
function service_up {
    SERVICE=$1
    COUNT=1
    MAXCOUNT=30

    docker service ps $SERVICE --format "{{.CurrentState}}" 2>/dev/null | grep Running
    service_up=$?

    until [ $service_up -eq 0 ]; do
	echo "$COUNT: service $SERVICE unavailable"
	sleep 5
	docker service ps $SERVICE --format "{{.CurrentState}}" 2>/dev/null | grep Running
	service_up=$?
	if [ $COUNT -eq $MAXCOUNT ]; then
	    echo "service $SERVICE not found; giving up"
	    exit 1
	fi
	COUNT=$((COUNT+1))
    done

    echo "service $SERVICE up!"
}


##############################
## Deploy stack
##############################

# Check if docker stack has been deployed
docker service ps $SLURM_SERVICE --format "{{.CurrentState}}" 2>/dev/null | grep Running
service_up=$?

if [ $service_up -eq 1 ]; then
    docker stack deploy --with-registry-auth -c docker-compose.yaml $STACK_NAME;
fi

service_up $SLURM_SERVICE
service_up $SNAKEMAKE_SERVICE
CONTAINER=$(docker ps | grep cookiecutter-slurm_slurm | awk '{print $1}')


# Add local user id as user to container
add_slurm_user $LOCAL_USER_ID $CONTAINER

# Fix snakemake header to point to /opt/local/bin
docker exec $CONTAINER /bin/bash -c "head -1 /opt/local/bin/snakemake" | grep "/usr/local/bin"
if [ $? -eq 1 ]; then
    echo "Rewriting snakemake header to point to /opt/local/bin"
    docker exec $CONTAINER /bin/bash -c 'sed -i -e "s:/usr:/opt:" /opt/local/bin/snakemake'
fi

# Rewrite slurm config
modify_slurm_conf $CONTAINER
