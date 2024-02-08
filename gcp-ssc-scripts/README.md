# SSC startup scripts
These scripts simplify a spin-up process of SSC nodes. Initially designed for GCP, they can be easily reused for basically any Linux machine.

## Requirements
Ubuntu 20.04/22.04. Other Linux distributions are not yet tested though will likely work too.

## What do they do
- Install Go and other helper tools
- Create sscdserviceuser
- Build sscd (SSC daemon binary)
- Create systemd service for sscd
- Init sscd and adjust configuration files
- Modify configuration files depending of the node type - RPC, gRPC, archival and so on
- Start sscd service

## How to use

For GCP these scripts can be used as [startup scritps](https://cloud.google.com/compute/docs/instances/startup-scripts/linux). For other cases you can just run one of these scripts manually.