#!/bin/bash

set -e

FASTAI_SHELL_VERSION="0.2.0"

if [ -f ~/.fastai-zone ]; then
  current_zone=$(cat ~/.fastai-zone)
else
  current_zone='us-west1-b'
fi

# my preferred 1-GPU loads for compute engine
# as of 15th March, 2020
declare -A GPUS_IN_ZONES=(
  ["us-central1-a"]="t4 p4"
  ["us-central1-b"]="t4"
  ["us-central1-c"]="p4"
  ["us-central1-f"]="t4"
  ["us-east1-c"]="t4"
  ["us-east1-d"]="t4"
  ["us-east4-a"]="p4"
  ["us-east4-b"]="p4"
  ["us-east4-c"]="p4"
  ["us-west1-a"]="t4"
  ["us-west1-b"]="t4"
  ["us-west2-b"]="p4"
  ["us-west2-c"]="p4"
)

# preemptible per GPUs cost
# as of 15th March, 2020
declare -A PRICE_FOR_GPU=(
  ["t4"]="USD 0.11"
  ["p4"]="USD (0.216 0.2592)"
)

declare -A SYSTEM_FOR_GPU=(
  ["t4"]="1-24vcpus(4), 16GB Ram, 1-156GB Mem"
  ["p4"]="1-24vcpus(4), 8GB Ram, 1-156GB Mem"
)

test-zone () {
  zone=$1
  gpu=$2

  set +e
  count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID instances list | grep -c zone-tester)
  set -e

  if [[ "$count" == "1" ]]; then
    echo "Delete existing zone-tester instance"
    zone_for_exiting=$(gcloud compute --project=$DEVSHELL_PROJECT_ID instances list | grep zone-tester | sed 's/  */ /g' | cut -d ' ' -f2)
    gcloud compute --project=$DEVSHELL_PROJECT_ID -q instances delete zone-tester --zone $zone_for_exiting
  fi

  echo "Creating zone-tester instance for zone: $zone with GPU: $gpu"
  gcloud compute instances create zone-tester \
      --project=$DEVSHELL_PROJECT_ID \
      --zone=$zone \
      --subnet=fastai-net \
      --network-tier=PREMIUM \
      --machine-type="n1-highcpu-4" \
      --accelerator="type=nvidia-tesla-$gpu,count=1" \
      --image-family="pytorch-latest-gpu" \
      --image-project=deeplearning-platform-release \
      --maintenance-policy=TERMINATE \
      --boot-disk-size=30GB \
      --boot-disk-type=pd-ssd \
      --boot-disk-device-name=zone-tester

  echo ""
  echo "The zone: $zone has enough resources for the $gpu GPU."
  echo ""

  echo "Deleting zone-tester instance"
  gcloud compute --project=$DEVSHELL_PROJECT_ID -q instances delete zone-tester --zone=$zone
}

create_snapshot () {
  echo "Creating disk-snapshot (fastai-boot-1) instance for zone: $zone."
  gcloud compute --project=$DEVSHELL_PROJECT_ID disks snapshot fastai-boot-1 --zone=$current_zone --snapshot-names=fastai-boot-1
}

delete_snapshot () {
  set +e
  snapshot_count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID snapshots list | grep -c fastai-boot-1)
  set -e

  if [[ "$snapshot_count" == "1" ]]; then
    echo "Deleting disk-snapshot (fastai-boot-1) instance."
    gcloud compute --project=$DEVSHELL_PROJECT_ID snapshots -q delete fastai-boot-1
  fi
}

create_disk_from_snapshot () {
  echo "Creating disk from disk-snapshot (fastai-boot-1) instance for zone: $zone type:pd-ssd with size: 50GB."
  gcloud compute --project=$DEVSHELL_PROJECT_ID disks create fastai-boot-1 --zone=$zone --type=pd-ssd --source-snapshot=fastai-boot-1 --size=50GB
}

list-zones () {
  echo ""
  echo "Current zone: $current_zone."
  echo ""
  for z in "${!GPUS_IN_ZONES[@]}"; do
    echo " * $z (available gpus: ${GPUS_IN_ZONES[$z]})"
  done
  echo ""
}

switch-to () {
  zone=$1

  if [[ "$zone" == "" ]]; then
    echo ""
    echo "Specify the zone as 'fastai switch-to <zone>'"
    echo "
    "
    return 1
  fi

  if [[ "${GPUS_IN_ZONES[$zone]}" == "" ]]; then
    echo ""
    echo "Fastai shell does not support the zone: '$zone'"
    echo "Use one of the following zones:"
    echo ""

    for z in "${!GPUS_IN_ZONES[@]}"; do
      echo " * $z"
    done

    echo ""

    return 1
  fi

  echo "Stop the current instance, if exists"
  stop

  set +e
  disk_count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID disks list | grep -c fastai-boot-1)
  set -e

  ## If there's a disk, we need to move it to the target zone
  if [[ "$disk_count" == "1" ]]; then
    # Create the snapshot
    echo "Creating a snapshot for the existing disk"
    delete_snapshot
    create_snapshot

    # Delete the existing disk
    echo "Deleting the current disk"
    delete_boot_disk

    # Create the disk on the target zone based on the snapshot
    echo "Creating a disk in $zone based on the snapshot"
    create_disk_from_snapshot

    # Delete the snapshot
    echo "Deleting the snapshot"
    delete_snapshot
  fi

  echo $zone > ~/.fastai-zone
  echo "Availability zone updated to '$zone'"
}

create_network () {
  set +e
  has_network=$(gcloud compute --project=$DEVSHELL_PROJECT_ID networks list | grep -c fastai-net)
  set -e

  if [[ "$has_network" == "0" ]]; then
    echo "Creating a network (fastai-net) with firewall rules (allow-all-fastai-net)."
    gcloud compute --project=$DEVSHELL_PROJECT_ID networks create fastai-net --subnet-mode=auto
    # may need to setup forwarding protocols/ports
    gcloud compute --project=$DEVSHELL_PROJECT_ID firewall-rules create allow-all-fastai-net --direction=INGRESS --priority=1000 --network=fastai-net --action=ALLOW --rules=all --source-ranges=0.0.0.0/0
  fi 
}

delete_network () {
  set +e
  has_network=$(gcloud compute --project=$DEVSHELL_PROJECT_ID networks list | grep -c fastai-net)
  set -e

  if [[ "$has_network" == "0" ]]; then
    echo "Deleting firewall-rules (allow-all-fastai-net) and network (fastai-net)." 
    gcloud compute --project=$DEVSHELL_PROJECT_ID firewall-rules -q delete allow-all-fastai-net
    gcloud compute --project=$DEVSHELL_PROJECT_ID networks delete -q fastai-net
  fi
}

create_boot_instance () {
  set +e
  instance_count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID instances list | grep -c fastai-boot-1)
  set -e

  # No need to create the boot instance if it's already exists
  if [[ "$instance_count" == "1" ]]; then
    return 0
  fi

  set +e
  has_disk=$(gcloud compute --project=$DEVSHELL_PROJECT_ID disks list | grep -c fastai-boot-1)
  set -e

  if [[ "$has_disk" == "0" ]]; then
    # NOTE: Do we need n1-highcpu-8 and nvidia-tesla-k80,count=1 type??
    echo "Creating a boot instance (fastai-boot-1)." 
    gcloud compute instances create fastai-boot-1 \
      --project=$DEVSHELL_PROJECT_ID \
      --zone=$current_zone \
      --subnet=fastai-net \
      --network-tier=PREMIUM \
      --machine-type="n1-highcpu-8" \
      --accelerator="type=nvidia-tesla-k80,count=1" \
      --image-family="ubuntu-1804-lts" \
      --image-project=ubuntu-os-cloud \
      --maintenance-policy=TERMINATE \
      --boot-disk-size=50GB \
      --boot-disk-type=pd-ssd \
      --boot-disk-device-name=fastai-boot-1 \
      --no-boot-disk-auto-delete
  else
    echo "There's an existing boot disk. Try 'fastai start' or 'fastai destroy'"
    exit 1
  fi
}

delete_boot_instance () {
  set +e
  count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID instances list | grep -c fastai-boot-1)
  set -e

  if [[ "$count" == "1" ]]; then
    echo "Deleting a boot instance (fastai-boot-1) in zone: $current_zone."
    gcloud compute --project=$DEVSHELL_PROJECT_ID -q instances delete fastai-boot-1 --zone=$current_zone
  fi
}

delete_boot_disk () {
  set +e
  count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID disks list | grep -c fastai-boot-1)
  set -e

  if [[ "$count" == "1" ]]; then
    echo "Deleting a boot disk (fastai-boot-1) in zone: $current_zone."
    gcloud compute --project=$DEVSHELL_PROJECT_ID -q disks delete fastai-boot-1 --zone=$current_zone
  fi
}

wait_for_ssh () {
  instance_name=$1

  while :
  do
    set +e
    gcloud compute --project $DEVSHELL_PROJECT_ID ssh --zone $current_zone $instance_name -- "echo 'SSH is ready'"
    exit_code=$?
    set -e

    if [[ "$exit_code" == "0" ]]; then
      break
    fi
    sleep 1
    echo "Trying again"
  done
}

wait_for_command () {
  instance_name=$1
  command=$2

  while :
  do
    echo -ne "."

    set +e
    gcloud compute --project $DEVSHELL_PROJECT_ID ssh --zone $current_zone $instance_name -- "$command" > /dev/null 2>&1
    exit_code=$?
    set -e

    if [[ "$exit_code" == "0" ]]; then
      break
    fi
    sleep 1
  done

  echo "."
}

create () {
  echo "Ensure fastai network"
  create_network

  echo "Creating the boot instance"
  create_boot_instance

  echo "Waiting for SSH "
  wait_for_ssh "fastai-boot-1"

  # TODO: uncomment
  echo "Setting up the instance"
  # setup_script="https://raw.githubusercontent.com/arunoda/fastai-shell/master/setup-gce.sh?__ts=$RANDOM"
  # gcloud compute --project $DEVSHELL_PROJECT_ID ssh --zone $current_zone "fastai-boot-1" -- "curl $setup_script > /tmp/setup.sh && bash /tmp/setup.sh"

  echo "Deleting the boot instance"
  delete_boot_instance

  echo ""
  echo "Your fastai instance is ready."
  echo "Run 'fastai start' to get started"
  echo ""
}

start () {
  echo ""
  echo "Current zone: $current_zone"
  echo "Run one of the following commands:"
  echo ""

  gpus=(${GPUS_IN_ZONES[$current_zone]})
  for gpu in ${gpus[@]}; do
    echo " * fastai $gpu ($gpu gpu, ${SYSTEM_FOR_GPU[$gpu]} - \$${PRICE_FOR_GPU[$gpu]}/hour)"
  done
  echo " * fastai nogpu (1cpu, 3.75GB RAM - \$0.02/hour)"
  echo ""

}

show_jupyter_link () {
  echo -ne "Waiting for Jupyter "
  wait_for_command "fastai-1" "curl http://localhost:8080"

  external_ip=$(gcloud compute --project=$DEVSHELL_PROJECT_ID instances list | grep fastai-1 | sed 's/  */ /g' | cut -d ' ' -f6)
  echo "Access notebooks via http://${external_ip}:8080"
}

start_instance() {
  machine_type=$1
  gpu_type=$2

  set +e
  instance_count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID instances list | grep -c fastai-1)
  set -e

  # If the machine already started, simply show the start script
  if [[ "$instance_count" == "1" ]]; then
    echo "The fastai instance is already started"
    echo "To change the instance type, first stop it with 'fastai stop'"
    echo "Otherwise here's the URL:"
    show_jupyter_link
    return 0
  fi

  echo "Creating instance"

  # TODO : check these
  # export IMAGE_FAMILY="pytorch-latest-gpu" # or "pytorch-latest-cpu" for non-GPU instances
  # --image-project=deeplearning-platform-release \
  # --image-family=$IMAGE_FAMILY \
  # --metadata="install-nvidia-driver=True" \
  if [[ "$gpu_type" == "nogpu" ]]; then
    gcloud compute instances create fastai-1 \
      --project=$DEVSHELL_PROJECT_ID \
      --zone=$current_zone \
      --subnet=fastai-net \
      --network-tier=PREMIUM \
      --machine-type=$machine_type\
      --no-restart-on-failure \
      --maintenance-policy=TERMINATE \
      --disk=name=fastai-boot-1,device-name=fastai-boot-1,mode=rw,boot=yes \
      --preemptible
  else
    gcloud compute instances create fastai-1 \
      --project=$DEVSHELL_PROJECT_ID \
      --zone=$current_zone \
      --subnet=fastai-net \
      --network-tier=PREMIUM \
      --machine-type=$machine_type \
      --accelerator="type=$gpu_type,count=1" \
      --no-restart-on-failure \
      --maintenance-policy=TERMINATE \
      --disk=name=fastai-boot-1,device-name=fastai-boot-1,mode=rw,boot=yes \
      --preemptible
  fi

  show_jupyter_link
}

p4 () {
  start_instance "n1-highmem-4" "nvidia-tesla-p4"
}

t4() {
  start_instance "n1-highmem-8" "nvidia-tesla-t4"
}

nogpu () {
  start_instance "n1-standard-4" "nogpu"
}

stop () {
  set +e
  instance_count=$(gcloud compute --project=$DEVSHELL_PROJECT_ID instances list | grep -c fastai-1)
  set -e

  # If the machine already started, simply show the start script
  if [[ "$instance_count" == "1" ]]; then
    gcloud compute instances delete fastai-1 -q --project=$DEVSHELL_PROJECT_ID --zone=$current_zone
  fi
}

destroy () {
  delete_boot_instance
  stop
  delete_boot_disk
  delete_snapshot
}

version () {
  echo $FASTAI_SHELL_VERSION
}

help() {
  echo ""
  echo "fastai-shell"
  echo "visit: https://github.com/arunoda/fastai-shell"
  echo "----------------------------------------------"
  echo ""
  echo "fastai create                 - create a fastai boot disk"
  echo "fastai start                  - start a new fastai instance"
  echo "fastai stop                   - stop the current fastai instance"
  echo "fastai list-zones             - List supported availability zones"
  echo "fastai switch-to <zone>       - switch-to the availability zone"
  echo "fastai destroy                - destroy everything created by the fastai-shell"
  echo "fastai test-zone <zone> <gpu> - test whether we can create instances in the given zone"
  echo ""
}

command=$1

$command $2 $3 $4 $5
