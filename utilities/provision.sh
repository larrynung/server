#!/bin/bash
set -e

DROPLET_ONE_NAME="${1:-one}"

if [ -z "$DIGITALOCEAN_ACCESS_TOKEN" ]; then
  echo "Error: Please set \$DIGITALOCEAN_ACCESS_TOKEN to continue" >&2
  exit 1
fi

if [ ! -f "docker-compose.yml" ]; then
  echo "Error: can't find a docker-compose.yml in the current directory" >&2
  exit 2
fi

if ! which docker-machine > /dev/null; then
  curl -L https://github.com/docker/machine/releases/download/v0.10.0/docker-machine-`uname -s`-`uname -m` >/tmp/docker-machine
  chmod +x /tmp/docker-machine
  sudo mv /tmp/docker-machine /usr/local/bin/docker-machine
  echo "* Installed docker-machine"
fi

if ! which doctl > /dev/null; then
  wget -qO- https://github.com/digitalocean/doctl/releases/download/v1.6.0/doctl-1.6.0-linux-amd64.tar.gz  | tar xz
  sudo mv ./doctl /usr/local/bin
  echo "* Installed doctl"
fi

echo "* Fetching old ssh keys..."
OLD_SSH_KEYS="$(doctl compute ssh-key list \
  | grep $DROPLET_ONE_NAME \
  | awk '{ print $1 }' \
  | tr '\n' ' ')"

echo "* Creating droplet to deploy containers..."
docker-machine create \
  --driver digitalocean \
  --digitalocean-access-token $DIGITALOCEAN_ACCESS_TOKEN \
  --digitalocean-region nyc1 \
  --digitalocean-private-networking \
  --digitalocean-size 512mb \
  $DROPLET_ONE_NAME

echo "* Sourcing docker environment..."
eval $(docker-machine env $DROPLET_ONE_NAME)

sleep 10

# echo "* Mounting shared volume for database in new droplet..."
DROPLET_ONE="$(doctl compute droplet list $DROPLET_ONE_NAME --format ID | tail -1)"
DB_VOLUME="$(doctl compute volume list backstroke-data --format ID | tail -1)"
DROPLET_ATTACHED_TO_VOLUME=$(doctl compute volume list --no-header | awk '{ print $6  }' | sed -e 's/\[//g' -e 's/\]//g')
if ! doctl compute volume-action detach-by-droplet-id $DB_VOLUME $DROPLET_ATTACHED_TO_VOLUME; then
  echo "* Looks like the volume was detached already."
else
  echo "* Waiting a while for volume to detach..."
  sleep 10
fi
doctl compute volume-action attach $DB_VOLUME $DROPLET_ONE

echo "* Waiting a while for volume to attach..."
sleep 10
docker-machine ssh $DROPLET_ONE_NAME -- \
  "mkdir -p /data && mount -o discard,defaults /dev/disk/by-id/scsi-0DO_Volume_backstroke-data /data"
docker-machine ssh $DROPLET_ONE_NAME -- \
  "echo /dev/disk/by-id/scsi-0DO_Volume_backstroke-data /data ext4 defaults,nofail,discard 0 0 | tee -a /etc/fstab"

echo "* Bringing up containers with docker-compose..."
docker-compose up -d

echo "* Waiting a few seconds for everything to set up..."
sleep 30

echo "* Doing a health check on the system..."
if docker-machine ssh $DROPLET_ONE_NAME -- "curl http://localhost"; then
  echo "* Health check passed!"
else
  echo "* Health check failed, http://localhost:80 isn't accepting http requests!" >&2
  exit 3
fi

FLOATING_IP="$(doctl compute floating-ip list --format IP | tail -1)"
echo "* Floating IP is $FLOATING_IP. Assigning floating IP to new droplet..."
doctl compute floating-ip-action assign $FLOATING_IP $DROPLET_ONE
sleep 1

echo "* Doing health check on droplet behind floating ip..."
if curl http://$FLOATING_IP; then
  echo "* Health check passed!"
else
  echo "* Health check failed, http://$FLOATING_IP:80 isn't accepting http requests!" >&2
  exit 4
fi

# Remove all out-of-date droplets, leaving the one that was just deployed.
echo "* Removing previously deployed versions of app..."
PREVIOUSLY_DEPLOYED="$(doctl compute droplet list --tag-name deployed --format ID | tail -n +2)"
for i in $PREVIOUSLY_DEPLOYED; do
  doctl compute droplet delete -f $i
done

echo "* Removing stored ssh keys..."
echo $OLD_SSH_KEYS | xargs -n 1 doctl compute ssh-key delete

echo "* Tagging deployed droplet..."
doctl compute droplet tag $DROPLET_ONE --tag-name deployed

echo "* Complete!"