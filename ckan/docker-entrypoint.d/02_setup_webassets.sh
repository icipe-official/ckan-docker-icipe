#!/bin/bash

# Ensure CKAN's webassets cache directory exists. On CIFS mounts, ownership and
# permissions must be configured on the host mount; chown inside the container
# cannot reliably change them.
mkdir -p /var/lib/ckan/webassets
