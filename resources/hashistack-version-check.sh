#!/bin/bash

binary_version=$(${BUILDROOT}/usr/bin/${SUBIMAGE} --version |& head -n1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
binary_version=${binary_version#v}

echo $IMAGE_VERSION | grep -qE "^${binary_version}(-|$)" || {
    echo "Error: ${SUBIMAGE} binary version (${binary_version}) does not match image version (${IMAGE_VERSION})" >&2
    exit 1
}
