# Create snapshots PER COMPONENT (noble has 4)
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-main from mirror ubuntu-noble:main
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-restricted from mirror ubuntu-noble:restricted  
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-universe from mirror ubuntu-noble:universe
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-multiverse from mirror ubuntu-noble:multiverse

# Updates (2 components)
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-updates-main from mirror ubuntu-noble-updates:main
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-updates-restricted from mirror ubuntu-noble-updates:restricted

# Security (2 components)
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-security-main from mirror ubuntu-noble-security:main
sudo aptly snapshot create -config=/etc/aptly/aptly.conf noble-security-restricted from mirror ubuntu-noble-security:restricted
# Noble (4 snapshots → 4 components)
sudo aptly publish snapshot -config=/etc/aptly/aptly.conf \
  -distribution=noble \
  -component=main,restricted,universe,multiverse \
  noble-main noble-restricted noble-universe noble-multiverse \
  ubuntu

# Noble-updates (2 snapshots → 2 components)  
sudo aptly publish snapshot -config=/etc/aptly/aptly.conf \
  -distribution=noble-updates \
  -component=main,restricted \
  noble-updates-main noble-updates-restricted \
  ubuntu

# Noble-security (2 snapshots → 2 components)
sudo aptly publish snapshot -config=/etc/aptly/aptly.conf \
  -distribution=noble-security \
  -component=main,restricted \
  noble-security-main noble-security-restricted \
  ubuntu
