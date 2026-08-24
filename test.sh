1. Assure toi d'avoir les comptes nécessaire (AWS, DockerHub, GitHub) 
   et teste-les avec les scripts test_*_config.sh

git init        # start a fresh repository
git add .
git commit -m "Initial commit"
git branch -M main

# Use your GitHub Account 
env gh repo create DevCTx/SSH_vs_SSM_AWS_Jenkins_Deployments \
  --public \
  --description "Full CI/CD pipeline for a Java application: triggered by a GitHub webhook on push, built with Maven via Jenkins on local or on AWS EC2, automatic image tagging, push to DockerHub or AWS ECR, and deployment to AWS EC2 via SSH or SSM." \
  --source=. \
  --push


2. Définis la configuration de REGISTRE (dockerhub ou aws ecr) 
   et de protocole de transfert (SSH ou SSM) que tu veux tester

3. Installe l'instance EC2 qui hébergera l'application :
   ./aws_ec2_install/aws_ec2_app_install.sh <dockerhub|ecr> <ssh|ssm>

4. Installe Jenkins en local ou sur une nouvelle instance AWS :
   
   - En local :
   ./jenkins_install/jenkins_local_install.sh <dockerhub|ecr> <ssh|ssm>
   
   - Sur AWS (crée d'abord une nouvelle instance dédiée) :
   ./aws_ec2_install/aws_ec2_jenkins_install.sh <dockerhub|ecr> <ssh|ssm>
   ./jenkins_install/jenkins_aws_install.sh <dockerhub|ecr> <ssh|ssm>

5. Configure le GitHub webhook selon l'installation de Jenkins
   ./jenkins_install/setup_github_webhook.sh

6. Lance un test de déploiement sur la combinaison définie :
   ./test_deployments.sh <dockerhub|ecr> <ssh|ssm>



*. Pour tester une autre combinaison, relance simplement l'étape 6 avec
   d'autres arguments — tout se fait à chaud, aucune réinstallation nécessaire,
   excepté si le nouveau combo utilise un registre ou un transport différent.

   Solution cumulative :
      ./aws_ec2_install/aws_ec2_app_install.sh dockerhub ssh
      ./aws_ec2_install/aws_ec2_app_install.sh ecr ssm
   Dans ce cas l'ensemble des cas pourra être testé sur l'instance AWS de l'application