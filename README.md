# Project Bedrock — InnovateMart EKS Deployment

## Architecture

See `docs/architecture.png` for the full diagram.

Retail Store Sample App running on Amazon EKS (`project-bedrock-cluster`), backed by:
- RDS MySQL (catalog service)
- RDS PostgreSQL (orders service)
- DynamoDB (carts service)
- RabbitMQ (in-cluster, orders messaging)

Exposed via AWS Load Balancer Controller → ALB Ingress.

## Deployment Guide

### Prerequisites
- AWS CLI configured with credentials
- Terraform >= 1.11
- kubectl, helm, eksctl

### 1. Bootstrap remote state (one-time)
\`\`\`bash
aws s3api create-bucket --bucket bedrock-tfstate-alt-soe-tin-025-0082 --region us-east-1
aws s3api put-bucket-versioning --bucket bedrock-tfstate-alt-soe-tin-025-0082 --versioning-configuration Status=Enabled
\`\`\`

### 2. Provision infrastructure
\`\`\`bash
cd terraform/envs/dev
terraform init
terraform apply
\`\`\`

### 3. Connect kubectl
\`\`\`bash
aws eks update-kubeconfig --name project-bedrock-cluster --region us-east-1
\`\`\`

### 4. Deploy the application
\`\`\`bash
kubectl create namespace retail-app

eksctl create iamserviceaccount --cluster=project-bedrock-cluster --namespace=retail-app --name=carts \
  --attach-policy-arn=arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess --approve --region=us-east-1

helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=project-bedrock-cluster --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller --set region=us-east-1 --set vpcId=<vpc-id>

cd retail-store-sample-app/src/app/chart
helm dependency build
helm upgrade --install retail-store . -n retail-app -f ../../../../values-override.yaml \
  --set catalog.app.persistence.endpoint="<mysql-endpoint>:3306" \
  --set catalog.app.persistence.secret.password="<from Secrets Manager>" \
  --set orders.app.persistence.endpoint="<postgres-endpoint>:5432" \
  --set orders.app.persistence.secret.password="<from Secrets Manager>"

kubectl apply -f k8s-ingress.yaml
\`\`\`

### 5. Access the store
\`\`\`bash
kubectl get ingress -n retail-app
\`\`\`
Live URL: http://k8s-retailap-ui-6039ab69e6-1505796709.us-east-1.elb.amazonaws.com

## CI/CD

GitHub Actions (\`.github/workflows/ci.yml\`) runs \`terraform plan\` on every PR touching \`terraform/**\` and posts the plan as a PR comment. Merging to \`master\` triggers \`terraform apply\` automatically via OIDC (no long-lived AWS keys stored in GitHub).

## Teardown

\`\`\`bash
kubectl delete ingress ui -n retail-app
helm uninstall retail-store -n retail-app
helm uninstall aws-load-balancer-controller -n kube-system
kubectl delete namespace retail-app

cd terraform/envs/dev
terraform destroy

# Manual cleanup
aws s3 rm s3://bedrock-assets-alt-soe-tin-025-0082 --recursive
aws s3api delete-bucket --bucket bedrock-assets-alt-soe-tin-025-0082
aws s3 rm s3://bedrock-tfstate-alt-soe-tin-025-0082 --recursive
aws s3api delete-bucket --bucket bedrock-tfstate-alt-soe-tin-025-0082
aws logs delete-log-group --log-group-name /aws/eks/project-bedrock-cluster/cluster
aws logs delete-log-group --log-group-name /aws/lambda/bedrock-asset-processor
aws iam detach-role-policy --role-name github-oidc-bedrock --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-role --role-name github-oidc-bedrock
aws iam delete-access-key --user-name bedrock-dev-view --access-key-id AKIAQVVPB75O2P5UXEGC
aws iam delete-login-profile --user-name bedrock-dev-view
aws iam detach-user-policy --user-name bedrock-dev-view --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam delete-user-policy --user-name bedrock-dev-view --policy-name bedrock-s3-put
aws iam delete-user --user-name bedrock-dev-view
\`\`\`

**Cost reminder:** EKS cluster, NAT Gateway, RDS instances, and ALB incur ongoing charges. Tear down when not actively grading.
