# Jenkins CI/CD — Docker + JCasC + AWS

Self-configured **Jenkins platform** (Docker Compose + Configuration as Code),
installable **locally** or **on AWS**, with **4 combinable pipelines**: 
  - **registry** < DockerHub | ECR > **× deployment transport** < SSH | SSM >.

## Quick start

1. Select the **desired configuration** from the **decision table** below 
    - **Jenkins on local or on AWS ?**
    - **Registry on DockerHub or AWS ECR ?**
    - **Transport via SSH or SSM protocol ?**

2. **Install the required EC2 instances** (before anything else):
   
   - The **EC2 instance for the Application** (Mandatory)
   `aws_ec2_install/aws_ec2_app_install.sh <dockerhub|ecr> <ssh|ssm>` 
     - creates the target EC2 instance (application), 
     - attaches the IAM role matching the selected registry/transport, 
     - and generates the SSH key pairs if needed.

   - The **EC2 instance for running Jenkins on AWS** (if desired): 
   `aws_ec2_install/aws_ec2_jenkins_install.sh <dockerhub|ecr> <ssh|ssm>`
     - creates the EC2 instance that will host Jenkins, 
     - attaches the matching IAM role.

   - These scripts write the generated the env vars used by the Jenkins install scripts and the Jenkinsfiles.

3. **Install Jenkins**:
   - **on Local**: `jenkins_install/jenkins_local_install.sh <dockerhub|ecr> <ssh|ssm>`
     (exposed through a Cloudflare tunnel to have a reliable public IP for the GitHub webhook)
   - **OR on AWS**: `jenkins_install/jenkins_aws_install.sh <dockerhub|ecr> <ssh|ssm>`

4. **Set the GitHub webhook**: `jenkins_install/setup_github_webhook.sh` 
   (remotely via SSH when Jenkins is on AWS)

5. **Load the desired configuration and enable its pipeline(s)**: 
   - reload `jenkins_configs/reload_jenkins_config.sh <config-name>.yaml`


**All the scripts apply exactly the IAM/SSH/SSM permissions needed for the chosen combo, no more, no less (least-privilege principle).**

## Decision table

| Jenkins | Registry  | Transport | jenkins YAML file              | Jenkinsfile          |
|---------|-----------|-----------|--------------------------------|-----------------------|
| local   | DockerHub | SSH       | `any-dockerhub-ssh.yaml`       | `dockerhub_ssh_ec2`  |
| local   | DockerHub | SSM       | `local-dockerhub-ssm.yaml`     | `dockerhub_ssm_ec2`  |
| local   | ECR       | SSH       | `local-ecr-ssh.yaml`           | `ecr_ssh_ec2`        |
| local   | ECR       | SSM       | `local-ecr-ssm.yaml`           | `ecr_ssm_ec2`        |
| AWS     | DockerHub | SSH       | `any-dockerhub-ssh.yaml`       | `dockerhub_ssh_ec2`  |
| AWS     | DockerHub | SSM       | `aws-dockerhub-ssm.yaml`       | `dockerhub_ssm_ec2`  |
| AWS     | ECR       | SSH       | `aws-ecr-ssh.yaml`             | `ecr_ssh_ec2`        |
| AWS     | ECR       | SSM       | `aws-ecr-ssm.yaml`             | `ecr_ssm_ec2`        |

`any-dockerhub-ssh.yaml` covers both local and AWS Jenkins: SSH never makes an AWS API call, so where Jenkins runs has no impact on this particular file.

## Why a single `docker-aws-agent` image

Every combo uses the same `docker-aws-agent` image (Docker + AWS CLI), rather than a lighter DockerHub-only image for combos that don't touch AWS. 
  > Having the `aws` binary installed grants no access by itself — without a credential or an IAM role attached (see the decision table and `jenkins_configs/*.yaml`), any `aws ...` command simply fails. 

The extra few MB in the image carry no security cost, and a single agent to build, test, and maintain is simpler than juggling two.


## Repo structure

```
jenkins-ci-cd/
├── env_install/            # shared helpers (.env, public IP, IMDS)
├── aws_ec2_install/        # EC2 install scripts for Jenkins and App + IAM roles or SSH keys
├── cloudflare/             # tunnel created to get a local public IP address when Jenkins is local 
├── jenkins_install/        # Jenkins install scripts on local or on AWS + webhook setup
│   ├── jenkins_local_install.sh
│   ├── jenkins_aws_install.sh
│   ├── setup_github_webhook.sh
│   ├── controller/         # jenkins controller Dockerfile
│   └── agents/             # jenkins controller Dockerfiles
├── jenkins_configs/        # jenkins-config.yaml variants for desired configuration (see table)
│   └── reload_jenkins_config.sh
└── pipelines/              # Jenkinsfiles according to desired registry and transport protocol

```