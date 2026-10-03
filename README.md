<img width="1544" height="1018" alt="image" src="https://github.com/user-attachments/assets/cfd04231-2738-420e-814e-c2e4e06c9d53" />



## AWS | K3S Static Environment
Static Kubernetes Environment: infrastructure is persistent and application lifecycle is automated independently of infrastructure lifecycle.


🎯  Installation and Integration
```
✅ GitLab — source code, Terraform, Kubernetes manifests
✅ Terraform + reusable Terraform Modules
✅ AWS infrastructure / VM / networking / load balancers
✅ K3s / Kubernetes
✅ Velero + Velero UI — backup and restore
✅ Argo Events / Event-driven GitOps
✅ Kubernetes workloads and resources
```

🚀 
```
terraform init
terraform validate
terraform plan -var-file="template.tfvars"
terraform apply -var-file="template.tfvars" -auto-approve
```

🧩 Config 

```
scp -i ~/.ssh/<your pem file> <your pem file> ec2-user@<terraform instance public ip>:/home/ec2-user
chmod 400 <your pem file>
```

