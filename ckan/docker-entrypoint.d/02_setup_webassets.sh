#!/bin/bash

# CKAN's mounted data directory may be created by Docker as root. Ensure the
# webassets cache directory exists and is writable before uWSGI drops to ckan.
mkdir -p /var/lib/ckan/webassets
chown -R 92:92 /var/lib/ckan/webassets
