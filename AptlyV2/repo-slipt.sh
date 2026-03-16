# For noble (4 components)
sudo aptly publish snapshot \
  -config=/etc/aptly/aptly.conf \
  -distribution=ubuntu \
  -component=main,restricted,universe,multiverse \
  ubuntu-noble-20260315 ubuntu

# For updates (2 components)  
sudo aptly publish snapshot \
  -config=/etc/aptly/aptly.conf \
  -distribution=noble-updates \
  -component=main,restricted \
  ubuntu-noble-updates-20260315 ubuntu

# For security (2 components)
sudo aptly publish snapshot \
  -config=/etc/aptly/aptly.conf \
  -distribution=noble-security \
  -component=main,restricted \
  ubuntu-noble-security-20260315 ubuntu
