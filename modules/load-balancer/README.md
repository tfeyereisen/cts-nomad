# Overview and Usage

More documentation in Conflunece [here](https://confluence.exactsciences.net/pages/viewpage.action?pageId=120292600).

The sync is managed by a nomad job that runs [consul-terraform-sync](https://www.consul.io/docs/nia/installation/configuration)

The nomad job installs the sync-module directory into the container which contains the sync configuration (sync.hcl) and
the terraform code which updates the load balancer. 

The sync-job will template out the sync configuration.

Before running any terraform, auth to operations dev account for terraform state backend:

```commandline
eval $(ar2 408888269979 admin 123456)
```

In order to run the sync job:
```commandline
cd ./sync-job
terraform init
terraform apply
```

This terraform creates the sync job, but also the load balancer with listeners and certificate for *.exactsciences.net.

Once the job is running, any changes to the backend service will be reflected on the load balancer and in Route53.
View the sync-jobs logs to see what resources are changing. Whenever Consul detects a change in the service status,
the terraform will run and update the resources that need modification.

In order to test these changes, go into the backend_for_testing repo and change the version or the number of jobs 
that are running for a particular service, then run a terraform apply to modify the jobs in Nomad.

These jobs are configure to do canary deployments, so you will need to manually promote changes for the deployment to finish.
While in the canary deployment you potentially are running two different versions of the application. You should see this 
reflected as two different routes to the service with a header condition that will direct you to a particular version based
on the value you supply for this header. You will also always have a default hostname based condition that will route to all
versions of a service if the version header is not supplied.

The backend job is a web service that will return the environment and the version that is running.

```commandline
curl https://backend-test1.exactsciences.net
Hello from backend test1 2.0.3
curl https://backend-test2.exactsciences.net
Hello from backend test2 1.0.0
```

If I create a new deployment for test2 on version 2.0.0 then the canary deployment will begin and I will have multiple versions
of test2 running. By not supplying the header I am directed to a target group that contains both versions.

```commandline
curl https://backend-test2.exactsciences.net
Hello from backend test2 2.0.0
curl https://backend-test2.exactsciences.net
Hello from backend test2 1.0.0
```

I can use the special header to be directed to a single version explicitly if I desire:

```commandline
curl -H 'x-service-version: 1.0.0' https://backend-test2.exactsciences.net
Hello from backend test2 1.0.0
curl -H 'x-service-version: 2.0.0' https://backend-test2.exactsciences.net
Hello from backend test2 2.0.0
```


## Details
The sync-job will take input from Consul about the active services and use this to run terraform. 

There are two complicated pieces of this process, one is transforming variables the other is filtering services. 

### Filtering services
We want to run many nomad jobs that each synchronize a namespaces services to a single load balancer in that VPC. In order
to do this we are leveraging service tags to filter. For a particular namespace we find all services that have the tag:

consul-ingress-alb=[namespace]

The mechanics of this are a bit difficult as consul-terraform-sync doesnt offer this type of filtering natively via the sync.hcl 
configuration document. We are leveraging the built in capability of consul-template within Nomad template stanzas. This 
is done within the sync-job/sync.hcl.tmpl file which results in the sync configuration.

There are two levels of filtering, one is done by service stanzas and the other is done within the task stanza.

Service stanza:
```commandline
{{range services}}{{ if .Tags | contains "consul-ingress-alb=[namespace]" }}
service {
  name = "{{.Name}}"
  tag = "consul-ingress-alb=[namespace]"
  description = "all instances of the {{.Name}} service tagged with [namespace]"
}
{{end}}{{end}}
```

Task stanza:
```commandline
services = [{{range services}}{{ if .Tags | contains "consul-ingress-alb=[namespace]" }}"{{.Name}}",{{end}}{{end}}]
```

In both cases, the [namespace] variable needs to be replaced with the nomad namespace. The service stanza creates a subset of the service in consul that is tagged with the consul-ingress-alb tag. The task stanza references the service stanzas.

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
    node_datacenter = "es-operations-dev-dc1"
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