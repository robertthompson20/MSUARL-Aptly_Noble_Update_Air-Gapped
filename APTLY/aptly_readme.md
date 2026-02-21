
Technical Guide: Building Ubuntu Noble & Noble‑Security Mirrors with Aptly
A Script‑Free Walkthrough for Air‑Gapped Environments
This guide explains how to create, snapshot, and publish Ubuntu 24.04 (Noble) and Noble‑Security package repositories using Aptly. It is intended for users with only minimal background in Ubuntu, Aptly, or GPG, and consolidates the logic and corrections documented in the project files.


1. Introduction
Organizations maintaining air‑gapped systems often need a self‑contained Ubuntu package repository. The workflow outlined in the provided documents covers:

Creating filtered Ubuntu mirrors
Applying retry and network‑validation logic
Importing and validating keyrings
Building snapshots
Publishing repositories for offline use
Troubleshooting Aptly’s publishing behavior
The combined result is a reliable, repeatable process for maintaining up‑to‑date Ubuntu Noble and Noble‑Security mirrors.


2. What You Will Build
You will construct two repositories:
1. Noble main + universe
Sourced from:
http://archive.ubuntu.com/ubuntu
2. Noble‑Security main + universe
Sourced from:
http://security.ubuntu.com/ubuntu/
Both repositories will ultimately publish into:
/mnt/aptly/public/ubuntu


This directory can then be transferred to any offline system.


3. Prerequisites
Software
Install required tools:
sudo apt update
sudo apt install aptly gnupg wget ca-certificates

The documentation emphasizes Aptly, wget, and GPG as must‑have components.
Directory Setup
Aptly’s root directory must match its configuration:
/mnt/aptly
/mnt/aptly/public/ubuntu


Aptly Configuration
The Aptly version included in Ubuntu does not support filesystem endpoints (e.g., local:), which caused snapshot publishing failures until corrected. The working configuration includes options that eliminate unsupported features, disable signing/verification for simplicity, and restrict architectures to amd64.


4. GPG Handling
The security‑mirror documentation notes that:

GPG keys may be exported or imported into Aptly’s trusted store
Validation of keyrings is part of the expected environment checks
However, given the Aptly configuration used, signing and verification are disabled, making GPG optional during initial setup.
When ready to introduce signing:
gpg --full-generate-key



5. Mirror Workflow Overview
Across both documents, the workflow is consistent:

Validate environment
Ensure all required tools exist and Aptly’s config file is available.

Verify upstream network accessNoble mirror tests archive.ubuntu.com
Security mirror tests security.ubuntu.com
Create a filtered Aptly mirror
Filters exclude categories such as:

Cloud‑specific tools (azure, aws, gcp)
snapd
Installer packages
Firmware bundles
Update the mirror
The documents describe using exponential backoff retry logic to handle transient download errors.

Create a snapshot
A timestamped snapshot is created from each mirror.

Publish the snapshot
Critical corrections from the Aptly‑publish troubleshooting include:

Flags such as -distribution, -component, and -skip-signing must appear before the subcommand (publish snapshot)
The Ubuntu Aptly build cannot use custom filesystem endpoints
Publishing must follow the simple syntax documented in the files
Offline use
The final repository structure is validated by checking dists/ and pool/ directories.
Offline systems consume the repository with:
deb [trusted=yes] file:///path/to/ubuntu noble main universe




6. Noble vs Noble‑Security: What’s Different?
Both mirrors follow the same structure, but differ in:

Mirror	URI	Suite	Components
Noble	http://archive.ubuntu.com/ubuntu	noble	main, universe
Noble‑Security	http://security.ubuntu.com/ubuntu/	noble-security	main, universe

The security mirror also emphasizes:

GPG key export/import
Additional network validation


7. Validating the Final Repository
Once snapshots are published:

dists/noble/main/binary-amd64/ should exist
pool/main/ and pool/universe/ confirm component inclusion
Filters should result in a significantly smaller repo compared to a full mirror
These checks were part of the troubleshooting process leading to the corrected publishing flow.


8. Using the Repository Offline
Any system can use the mirror by pointing to the mounted directory:
deb [trusted=yes] file:///path/to/ubuntu noble main universe


This method requires no GPG setup when trusted=yes is specified, aligning with the configuration that disables signature verification.


9. Summary
This guide consolidates the structure, logic, and corrections necessary to replicate the mirroring workflow described across both project documents.
By following the outlined steps—environment validation, mirror creation, snapshotting, and corrected snapshot publishing—you can reliably produce both Noble and Noble‑Security repositories suitable for offline or air‑gapped environments.
