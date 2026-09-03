# Jenkins CI/CD — Docker + JCasC + AWS
 
**Same pipeline, four deployment strategies.** 

Comparison of **DockerHub** vs **a private registry (ECR)**, and **SSH** vs **SSM**, on a self-configured **Jenkins platform (Docker Compose + Configuration as Code)** that can be run **locally** or **on AWS**.
 
## Why this project
 
Should a production EC2 instance maintain an open SSH port and a key pair that must be protected indefinitely, or should it authenticate exclusively via an IAM role and SSM, without any open ports or keys?

This repository implements the **CI/CD pipeline for a single Java application using four variations [ DockerHub|ECR × SSH|SSM ]**, enabling the application to be run using different approaches and compared objectively.

![Architecture: GitHub push through Jenkins to EC2 deployment via SSH or SSM](docs/architecture.svg)


## Engineering decisions
 
- **One shared Jenkins library** — build/push/deploy/cleanup logic written once per registry/transport pair, never duplicated.
- **JCasC hot-reload** — switching the active combo is a config reload, not an image rebuild.
- **A single generic `docker-aws-agent` image** — Having the aws binary installed grants no access by itself — without a credential or an IAM role attached (see `jenkins_configs/*.yaml`), any aws ... command simply fails. The extra few MB in the image carry no security cost, and a single agent to build, test, and maintain is simpler than juggling two.
- **Least privilege per combo** — roles, security groups, and credentials scoped to exactly what each combo needs.
- **One persistent instance per combo** — created once, reused idempotently; no IP or credentials modifications.

  ### Why 4 instances, and not only 1 ?

    The first attempt used a single app instance, that I destroyed and recreated on every combo switch, to minimize AWS costs. 

    In practice this meant to regenerate SSH keys, IAM roles, IP addresses, and credentials each time — and Jenkins' credentials had to be resynced right after them, turning a simple "test another combo" into a complex reset that also needs to let port 22 activated to be sure to reaccess it even if the instance did not use it.

    Splitting into 4 persistent instances, each with a stable IP and its own combo-scoped role, removes that complexity entirely and — as a side effect — makes the four approaches easier to compare directly, since each instance behaves exactly as its combo dictates. 

    However, they share two security groups (with or without SSH access), because only transport rules influence the configuration of these groups, port 22 is thus only open when necessary.

  >| Combo | What the instance needs |
  >|---|---|
  >| dockerhub + ssh | SSH key, port 22 |
  >| dockerhub + ssm | IAM role: SSM |
  >| ecr + ssh | SSH key + IAM role: ECR |
  >| ecr + ssm | IAM roles: ECR + SSM |


## Prerequisites

### 1. Fork or clone this repo

Needed to get your own GitHub webhook. Fork:
```bash
gh repo fork https://github.com/DevCTx/SSH_vs_SSM_AWS_Jenkins_Deployments --clone
```
Or clone, drop the history, and push to your own repo:
```bash
git clone https://github.com/DevCTx/SSH_vs_SSM_AWS_Jenkins_Deployments
cd SSH_vs_SSM_AWS_Jenkins_Deployments

rm -rf .git && git init && git add . && git commit -m "Initial commit" && git branch -M main

gh repo create <your-account>/SSH_vs_SSM_AWS_Jenkins_Deployments --public \
  --description "Full CI/CD pipeline for a Java application: triggered by a GitHub webhook on push, built with Maven on Jenkins, automatic image tagging, push to DockerHub or AWS ECR, and deployment to AWS EC2 via SSH or SSM." \
  --source=. --push
```

### 2. GitHub token
 
*Settings > Developer settings > Personal access tokens > Fine-grained tokens > Generate new token*

- **Token name**: `jenkins-token` 
- **Description**: `Jenkins Token for SSH_vs_SSM_AWS_Jenkins_Deployments repository` 
- **Resource owner**: `<your GitHub account>` 
- **Expiration**: `7 days` or more if needed 
- **Repository Access**: Select **only** the `SSH_vs_SSM_AWS_Jenkins_Deployments` repository 
- **Repository permissions** (everything else on *No access*) :
 
>| Permission | Level | Why |
>|---|---|---|
>| Contents | Read-only | clone / checkout the sources |
>| Metadata | Read-only | required by default (auto) |
>| Commit statuses | Read and write | post the CI status on commits |
>| Webhooks | Read and write | Manage the hooks for a repository |
 
**Copy the token** and **save to** `.env`:
```
GITHUB_JENKINS_TOKEN=<github_pat_xxx>
GITHUB_OWNER=<your GitHub account>
REPO=<your account>/SSH_vs_SSM_AWS_Jenkins_Deployments
```
Test: `chmod 744 ./test_github_config.sh && ./test_github_config.sh` — expect
`✅ GITHUB_JENKINS_TOKEN matches GITHUB_OWNER` and `✅ REPO '...' is accessible`.
 
### 3. DockerHub token (only needed for DockerHub combos)
 
> *Account Settings > Personal Access Tokens > New access token*

- **Access Token Description**: `jenkins-myapp` 
- **Expiration Date**: `30 days` 
- **Access Permissions**: `Read, Write & Delete` 
 
**Copy the token** and **save to** `.env`:
```
DOCKER_USERNAME=<your Docker Hub account>
DOCKERHUB_PAT=<dckr_pat_xxx>
```
Test: `chmod 744 ./test_dockerhub_config.sh && ./test_dockerhub_config.sh` — expect `Login Succeeded`.
 
### 4. AWS CLI
 
Install the CLI, then configure it with an IAM admin user's access key
(needs rights to create roles/instances/IAM users — this account is only
used from your machine, never stored in `.env`):
https://docs.aws.amazon.com/fr_fr/cli/latest/userguide/getting-started-install.html

**Get your AWS credentials**
> *IAM > Users > Your Admin User > Security credentials > Access keys > Create access key*
- select **Command Line Interface (CLI)**
- **Description** : `jenkins-ci`
- **Copy** the credentials or **Download the .csv** out of the repo 
Click **Done**

**Configure the CLI**
```bash
aws configure   # access key, secret key, region, output format
```
Test: `aws sts get-caller-identity` — expect a JSON block with your `UserId`, `Account`, and `Arn`.


## Quick start

1. Select the **desired configuration**:
    - **Jenkins on local or on AWS ?**
    - **Registry on DockerHub or AWS ECR ?**
    - **Transport via SSH or SSM protocol ?**

2. **Install the required EC2 instances** (before anything else):
   
   - The **EC2 instance for the Application** (Mandatory) — one persistent, idempotent instance per combo (app-ec2-<registry>-<transport>); running this again for a combo that already has its instance does nothing new.
   
      `aws_ec2_install/aws_ec2_app_install.sh <dockerhub|ecr> <ssh|ssm>` 

      - creates the target EC2 instance (application), 
      - attaches the IAM role matching the selected registry/transport, 
      - and generates the shared SSH key pair if the transport is SSH.

   - The **EC2 instance for running Jenkins on AWS** (if desired):

      `aws_ec2_install/aws_ec2_jenkins_install.sh <dockerhub|ecr> <ssh|ssm>`

      - creates the EC2 instance that will host Jenkins, 
      - attaches the matching IAM role.

   - These scripts write the generated the env vars used by the Jenkins install scripts and the Jenkinsfiles.

3. **Install Jenkins**:
   - **on Local**: exposed through a Cloudflare tunnel to have a reliable public IP for the GitHub webhook
   
      `jenkins_install/jenkins_local_install.sh <dockerhub|ecr> <ssh|ssm>`

   - **OR on AWS**: 
   
      `jenkins_install/jenkins_aws_install.sh <dockerhub|ecr> <ssh|ssm>`

4. **Set the GitHub webhook** (remotely via SSH when Jenkins is on AWS)

    `jenkins_install/setup_github_webhook.sh` 

5. **Load the desired configuration and enable its pipeline(s)**: 
   
    `jenkins_configs/reload_jenkins_config.sh <config-name>.yaml`

6. **Run test for a given combo** :
  
    `./test_deployments.sh <dockerhub|ecr> <ssh|ssm>`

    - creates the instance if needed, loads its config, triggers the pipeline, and verifies the deployed tag on EC2
    - must be repeated for each combo to test.

**All the scripts apply exactly the IAM/SSH/SSM permissions needed for the chosen combo, no more, no less (least-privilege principle).**

## Testing all 4 combos in one session
 
Install Jenkins once with `ecr ssm` — the most demanding combo — so the
local IAM user (`aws-creds` Jenkins credential) is created right away and
reused by the other local combos too. Only DockerHub/SSH needs nothing
extra; the others all reuse this same credential:
```bash
./jenkins_install/jenkins_local_install.sh ecr ssm
./jenkins_install/setup_github_webhook.sh
```
Then run the smoke test for each combo, in any order — no other manual
step in between (each call provisions its own app instance if missing,
loads its config, and verifies the deployment):
```bash
./test_deployments.sh dockerhub ssh
./test_deployments.sh dockerhub ssm
./test_deployments.sh ecr ssh
./test_deployments.sh ecr ssm
```

## What each combo uses

The **transport** (SSH/SSM) drives the deployment mechanism and security
group; the **registry** (DockerHub/ECR) only drives build/push credentials
and whether ECR IAM roles are needed. The two axes are independent.

| | **dockerhub+ssh** | **dockerhub+ssm** | **ecr+ssh** | **ecr+ssm** |
|---|---|---|---|---|
| Jenkinsfile | `dockerhub_ssh_ec2` | `dockerhub_ssm_ec2` | `ecr_ssh_ec2` | `ecr_ssm_ec2` |
| Build/push credential — Jenkins **local** | `dockerhub-username` + `dockerhub-pat` | `dockerhub-username` + `dockerhub-pat` | `aws-creds` → `ecr get-login-password` | `aws-creds` → `ecr get-login-password` |
| Build/push credential — Jenkins on **AWS** | `dockerhub-username` + `dockerhub-pat` | `dockerhub-username` + `dockerhub-pat` | `jenkins-ec2-role` → `ecr get-login-password` | `jenkins-ec2-role` → `ecr get-login-password` |
| Deploy credential — Jenkins **local** | `app-ec2-ssh-key` | `aws-creds` → `ssm send-command` | `app-ec2-ssh-key` | `aws-creds` → `ssm send-command` |
| Deploy credential — Jenkins on **AWS** | `app-ec2-ssh-key` | `jenkins-ec2-role` → `ssm send-command` | `app-ec2-ssh-key` | `jenkins-ec2-role` → `ssm send-command` |
| IAM — app instance | *none* | `AmazonSSMManagedInstanceCore` | `AmazonEC2ContainerRegistryReadOnly` | both |
| IAM — Jenkins **local** user (`jenkins-local-aws-creds`, bound to credential `aws-creds`) | *none* | `AmazonSSMFullAccess` | `AmazonEC2ContainerRegistryFullAccess` | both |
| IAM — Jenkins on **AWS** (`jenkins-ec2-role`, shared by every combo — policies accumulate, never removed) | *none* | `AmazonSSMFullAccess` | `AmazonEC2ContainerRegistryFullAccess` | both |
| App security group | `app-ec2-ssh-sg` (port 22 open) | `app-ec2-ssm-sg` (never port 22) | `app-ec2-ssh-sg` (port 22 open) | `app-ec2-ssm-sg` (never port 22) |
| Deployment mechanism | `docker run` over SSH | `docker compose up` via SSM | `docker run` over SSH | `docker compose up` via SSM |
| AWS API call from Jenkins | none | `ssm send-command` | `ecr get-login-password` / `batch-delete-image` | both |

Each `aws ...` call is identical in both cases; only the location where the
AWS CLI looks for its credentials differs. `aws-creds` injects
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as environment variables. On
AWS, these variables are absent; the CLI then turns to the Instance
Metadata Service (IMDS), which provides automatically generated temporary
credentials derived from the instance's own IAM role (`jenkins-ec2-role`).
These credentials are automatically renewed by AWS approximately every 6
hours; nothing is static or stored, so there is no risk of leakage. The
rest of the code remains the same in both cases.


## Uninstall

Every `*_install.sh` has a matching `*_uninstall.sh`, undoing exactly what
its counterpart created — never more. Shared resources (an SSH key or
security group reused by another combo, an ECR repo shared by both ECR
combos) are left alone by default, since removing them could break a
sibling combo still in use; each script says so explicitly when it skips
something.

```bash
./aws_ec2_install/aws_ec2_app_uninstall.sh <dockerhub|ecr> <ssh|ssm>   # terminate that combo's app instance
./aws_ec2_install/aws_ec2_jenkins_uninstall.sh                         # terminate the Jenkins-on-AWS instance
./jenkins_install/jenkins_local_uninstall.sh                           # tear down the local Jenkins stack
./jenkins_install/jenkins_aws_uninstall.sh                             # tear down Jenkins on AWS without terminating the instance
```

## Repo structure

```
SSH_vs_SSM_AWS_Jenkins_Deployments/
├── aws_ec2_install/      # EC2 install scripts: one instance per combo + optional Jenkins-on-AWS instance
│   ├── aws_ec2_app_install.sh       # creates/reuses app-ec2-<registry>-<transport>
│   ├── aws_ec2_app_uninstall.sh     # terminates one combo's app instance
│   ├── aws_ec2_jenkins_install.sh   # creates/reuses the Jenkins-on-AWS instance
│   ├── aws_ec2_jenkins_uninstall.sh # terminates the Jenkins-on-AWS instance
│   └── aws_shared_library.sh        # AMI lookup, security groups, IAM roles/profiles, ...
├── cloudflare/           # script to create a tunne for a public IP address when Jenkins is local
├── docs/
│   └── architecture.svg            # diagram used in this README
├── env_install/          # shared helpers (.env, public IP, IMDS)
├── java_app/             # the demo Spring Boot app built and deployed by every combo
│   ├── pom.xml
│   └── src/main/
│       ├── java/com/example/Application.java
│       └── resources/
│           ├── application.properties      # server.port=3080, matches APP_CONTAINER_PORT
│           └── static/index.html
├── jenkins_install/      # Jenkins install scripts on local or on AWS + webhook setup
│   ├── jenkins_local_install.sh
│   ├── jenkins_local_uninstall.sh
│   ├── jenkins_aws_install.sh
│   ├── jenkins_aws_uninstall.sh
│   ├── setup_github_webhook.sh
│   ├── controller/                 # jenkins controller Dockerfile + active jenkins-config.yaml
│   └── agents/                     # base / maven / docker-aws agent Dockerfiles
├── jenkins_configs/      # jenkins-config.yaml variants for desired configuration (see table)
│   └── reload_jenkins_config.sh
├── pipelines/            # Jenkinsfile + Dockerfile per combo (registry_transport_ec2/)
│   ├── dockerhub_ssh_ec2/
│   ├── dockerhub_ssm_ec2/
│   ├── ecr_ssh_ec2/
│   └── ecr_ssm_ec2/
├── test_github_config.sh
├── test_dockerhub_config.sh
└── test_deployments.sh   # test per combo
```

## Credits

If you reuse this repo or part of it, please keep this attribution:

"originally built by [DevCTx](https://github.com/DevCTx) —
[SSH_vs_SSM_AWS_Jenkins_Deployments](https://github.com/DevCTx/SSH_vs_SSM_AWS_Jenkins_Deployments)."