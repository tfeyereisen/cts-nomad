#!/bin/bash

# AWS SSM Agent
sudo snap install amazon-ssm-agent --classic

# Tools
sudo apt-get update
sudo apt-get -y install net-tools zip jq

# Install Consul
export CONSUL_VERSION="1.9.3"
sudo wget https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip
sudo unzip consul_${CONSUL_VERSION}_linux_amd64.zip
sudo chown root:root consul
sudo mv consul /usr/local/bin/
sudo mkdir -p /etc/consul.d
sudo mkdir -p /opt/consul
sudo chmod -R 777 /opt/consul

# Install Nomad
export NOMAD_VERSION="1.0.1"
sudo wget https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip
sudo unzip nomad_${NOMAD_VERSION}_linux_amd64.zip
sudo chown root:root nomad
sudo mv nomad /usr/local/bin/
sudo mkdir -p /etc/{nomad-server.d,nomad-client.d}
sudo mkdir -p /opt/nomad/{server,client}
sudo chmod -R 777 /opt/nomad