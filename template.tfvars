
###  ---  K3S Default Template  ---  ###
region         = "us-west-2"
ami_id                    = "ami-0345dd2cef523536e"
instance_type             = "t3.large"

master_count              = 3
worker_count              = 3
root_volume_size          = 100
root_volume_type          = "gp3"

ssh_allowed_cidr          = "0.0.0.0/0"
web_allowed_cidr          = "0.0.0.0/0"

security_group_name       = "k3s-sg"
security_group_description = "K3s cluster security group"
ssh_public_key_path       = "~/.ssh/id_rsa.pub"
ssh_private_key_path      = "~/.ssh/id_rsa" 


