# cts-nomad
This project deploys a simple Consul-Nomad cluster for the purpose of demonstrating how we can use [Consul Terraform Sync](https://www.consul.io/docs/nia/installation/configuration) (CTS) to load balance public DNS names into services running on Nomad.

For example, you might run a front end microservice that you want to expose through an AWS ALB on a domain name.

```
curl https://service.mydomain.com
```

Your service might be deployed as several Nomad jobs on randomized ports. 
CTS is responsible for updating DNS, the load balancer rules, and target groups to make sure that service.mydomain.com is routed to healthy Nomad jobs.

# TOC
  * [Requirements](#requirements)
  * [Infrastructure](#infrastructure)
  * [Deploy](#deploy)
  * [Consul Terraform Sync](#consul-terraform-sync)
  * [Examples](#examples


# Requirements
In order to run this demo, you need an AWS account with a public domain/hosted zone.

The public domain/hosted zone are required, because the load balancer routes based on host headers.

This environment is a demo environment, it does not follow HashiCorp Best practices for a production deployment.
Notably, we should not run Consul and Nomad server on the same machine, we should not run Nomad client on 
a machine that is heavily used for other workloads, and we should enable ACL. 

# Infrastructure
This folder contains all of the infrastructure automation to support the demo.

## AMI
The AMI that the Autoscaling Group LAunch Configurations reference needs to be built.
You can build this with the packerfile in the build folder.
Run packer build after authenticating to your AWS accout to create the AMI before running the Terraform.

```
cd build
packer build packer.json
```

The terraform will create:
* EC2 instances in an Autoscaling group
* Load balancer and certificate to offload SSL and target the EC2 instances
* DNS names to point to load balancer
* IAM policies and roles for the EC2 instances
* VPC resources such as security groups

The result of this infrastructure is:
* Consul server cluster
* Nomad server cluster
* Nomad client cluster
* DNS and load balancer for consul.<domain> and nomad.<domain>
* Load balancer for Nomad jobs
* Nomad job running CTS

## ACL System
ACL are disabled on this cluster. 

# Deploy

## Build AMI
The base AMI is created with Packer.
This AMI contains some general tools, Consul/Nomad binaries, and some supporting directories.

```
cd build
packer build packer.json
```
## Deploy Terraform
Create a terraform.auto.tfvars with the following variables:

```
zoned_id = <your Route53 public hosted zone ID>
domain = <your domain that you can use to verify certificates>
```

```
terraform init
terraform apply
```


# Consul Terraform Sync
The CTS job reacts to service changes in Consul for services that are tagged appropriately.
To register a service with CTS supply the following details in the Nomad job service registration stanza:
```
service {
    name = "service"
    tags = ["consul-ingress-alb=us-east-1"]
    meta = {
        hostname = "service"
        version  = "1"        # Optional
        subdomain = "app"     # Optional
    }
}
```

These tags and meta data are what CTS is looking for in order to take actions.

The sync is managed by a nomad job that runs [consul-terraform-sync](https://www.consul.io/docs/nia/installation/configuration)

The nomad job installs the sync-module directory into the container which contains the sync configuration (sync.hcl) and
the terraform code which updates the load balancer. 

The sync-job will template out the sync configuration.

This terraform creates the sync job, but also the load balancer with listeners and certificate for *.<domain>.

Once the job is running, any changes to the backend service will be reflected on the load balancer and in Route53.
View the sync-jobs logs to see what resources are changing. Whenever Consul detects a change in the service status,
the terraform will run and update the resources that need modification.

## Canary Deployments
These jobs are configure to do canary deployments, so you will need to manually promote changes for the deployment to finish.
While in the canary deployment you potentially are running two different versions of the application. You should see this 
reflected as two different routes to the service with a header condition that will direct you to a particular version based
on the value you supply for this header. You will also always have a default hostname based condition that will route to all
versions of a service if the version header is not supplied.

The backend job is a web service that will return the environment and the version that is running.

```commandline
curl https://backend-test1.domain
Hello from backend test1 2.0.3
curl https://backend-test2.domain
Hello from backend test2 1.0.0
```

If I create a new deployment for test2 on version 2.0.0 then the canary deployment will begin and I will have multiple versions
of test2 running. By not supplying the header I am directed to a target group that contains both versions.

```commandline
curl https://backend-test2.domain
Hello from backend test2 2.0.0
curl https://backend-test2.domain
Hello from backend test2 1.0.0
```

I can use the special header to be directed to a single version explicitly if I desire:

```commandline
curl -H 'x-service-version: 1.0.0' https://backend-test2.domain
Hello from backend test2 1.0.0
curl -H 'x-service-version: 2.0.0' https://backend-test2.domain
Hello from backend test2 2.0.0
```


## Details
The sync-job will take input from Consul about the active services and use this to run terraform. 

There are two complicated pieces of this process, one is transforming variables the other is filtering services. 

### Filtering services
We want to run many nomad jobs that each synchronize a regions services to a single load balancer in that VPC. In order
to do this we are leveraging service tags to filter. For a particular region we find all services that have the tag:

consul-ingress-alb=[region]

This concept can be etended further to specific Nomad namespaces/AWS accounts/etc.

We are leveraging the built in capability of consul-template within Nomad template stanzas. This 
is done within the sync-job/sync.hcl.tmpl file which results in the sync configuration.

There are two levels of filtering, one is done by service stanzas and the other is done within the task stanza.

Service stanza:
```commandline
{{range services}}{{ if .Tags | contains "consul-ingress-alb=[region]" }}
service {
  name = "{{.Name}}"
  tag = "consul-ingress-alb=[region]"
  description = "all instances of the {{.Name}} service tagged with [region]"
}
{{end}}{{end}}
```

Task stanza:
```commandline
services = [{{range services}}{{ if .Tags | contains "consul-ingress-alb=[region]" }}"{{.Name}}",{{end}}{{end}}]
```

In both cases, the [region] variable needs to be replaced with the region. The service stanza creates a subset of the service in consul that is tagged with the consul-ingress-alb tag. The task stanza references the service stanzas.

This will create a list of all services in consul that have the tag which should be monitored by this instance of the consul-terraform-sync job.

### Transforming variables.
Consul will send updates to the filtered service to Terraform as a variable called services whose data structure is 
defined in ./sync-module/variables.tf. It looks like this:

```commandline
services = {
  "nomad_blahblahbah" : {
    id              = "nomad_blahblahbah"
    name            = "backend"
    address         = "172.29.14.145"
    port            = 23940
    meta            = {
      environment     = "test1"
      external-source = "nomad"
      namespace       = "test-ns"
      service         = "backend"
      version         = "2.0.2"
    }
    tags            = ["test1"]
    namespace       = "default"
    status          = "passing"
    node            = "ip-172-29-14-145"
    node_id         = "1809d432-7c4d-f9e7-7559-74eadac55f92"
    node_address    = "172.29.14.145"
    node_datacenter = "dc1"
    node_tagged_addresses = {
      lan      = "172.29.14.145"
      lan_ipv4 = "172.29.14.145"
      wan      = "172.29.14.145"
      wan_ipv4 = "172.29.14.145"
    }
    node_meta = {
      consul-network-segment = ""
    }
  },
  ...
```

This first thing we do is remap the data structure into a nested map where each top level key is the
service_name-environment and the value is the services object filtered to that service/environment

```commandline
service-env = {          # e.g. backend-test1
    services = {         # same data structure as above for services
    }
}
```

Then we loop over each service/environment and run the submodule service-routes which takes in the same service variable.
This module is responsible for all the work on the load balancer, target groups and Route53.

There is some useful debugging information within the sync-job on the filesystem. The terraform is executed in a workspace
at local/consul-service-ingress. This workspace contains all of the terraform files, including the terraform.tfvars which is the
raw inpout sent to the module, the services variable. I have added a services_map.json file which is the result of our
transformation above, where we remapped the services based on service/environment. 

Other than these files, it is helpful to review the logs of the task in Nomad and inspect the load balancer/rules 
within the AWS GUI.

# Examples