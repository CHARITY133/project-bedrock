# Project Bedrock

InnovateMart's first production-grade EKS deployment — Tinyuka capstone (Cloud DevOps Engineer track).

## What's deployed

- **VPC** (`project-bedrock-vpc`) — public/private subnets across 2 AZs in `us-east-1`, single NAT gateway
- **EKS cluster** (`project-bedrock-cluster`) — Kubernetes v1.34, 2× `t3.small` managed node group
- **Data layer** — RDS MySQL (Catalog), RDS PostgreSQL (Orders), DynamoDB (Carts, with `idx_global_customerId` GSI), all credentials in Secrets Manager
- **Application** — `retail-store-sample-app` deployed via Helm, exposed through an ALB Ingress (AWS Load Balancer Controller)
- **Security** — `bedrock-dev-view` IAM user with `ReadOnlyAccess` + EKS Access Entry scoped to the `retail-app` namespace (view-only)
- **Observability** — EKS control plane logging + CloudWatch Container Insights (Fluent Bit + CloudWatch Agent)
- **Serverless** — S3 bucket → Lambda (`bedrock-asset-processor`) triggered on upload, logs to CloudWatch
- **CI/CD** — GitHub Actions: `terraform plan` posted as a PR comment on pull requests, `terraform apply` on merge to `main`, authenticated via OIDC (no stored AWS keys)
- **Cost guardrails** — single NAT gateway, AWS Budget ($20/month, 80% email alert)

## Repo structure

```
terraform/
  envs/dev/          # root module — apply from here
  modules/            # (scaffolded, not all populated — most resources live in envs/dev/main.tf directly)
k8s/base/             # Ingress manifest
helm-values/          # values.yaml overriding the retail-store-sample-app chart's data layer
lambda/                # asset_processor.py
.github/workflows/    # CI/CD pipeline
grading.json           # terraform output -json (5 required outputs only)
```

Note: the `retail-store-sample-app` upstream repo (cloned from `aws-containers/retail-store-sample-app`) is **not** vendored into this repo — it's excluded via `.gitignore`. Clone it separately to deploy:
```bash
git clone https://github.com/aws-containers/retail-store-sample-app
```

## Deploying from scratch

### 1. Prerequisites
- AWS CLI configured with credentials that have broad provisioning rights (this project used an IAM user with admin-equivalent access)
- Terraform ≥ 1.11
- kubectl, Helm

### 2. Bootstrap the state bucket (one-time, manual — Terraform can't manage its own backend)
```bash
aws s3api create-bucket --bucket bedrock-tfstate-<your-suffix> --region us-east-1
aws s3api put-bucket-versioning --bucket bedrock-tfstate-<your-suffix> --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket bedrock-tfstate-<your-suffix> --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket bedrock-tfstate-<your-suffix> --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```
Update the bucket name in `terraform/envs/dev/backend.tf` to match.

### 3. Provision infrastructure
```bash
cd terraform/envs/dev
terraform init
terraform apply
```
This takes 15-25 minutes on a first run (EKS cluster + node group + RDS instances are the slow parts).

### 4. Connect kubectl
```bash
aws eks update-kubeconfig --region us-east-1 --name project-bedrock-cluster
```

### 5. Create the app namespace and DB credential secrets
```bash
kubectl create namespace retail-app

# Pull credentials from Secrets Manager into Kubernetes Secrets
CATALOG_USER=$(aws secretsmanager get-secret-value --secret-id bedrock/catalog-mysql --query 'SecretString' --output text | python -c "import sys, json; print(json.load(sys.stdin)['username'])")
CATALOG_PASS=$(aws secretsmanager get-secret-value --secret-id bedrock/catalog-mysql --query 'SecretString' --output text | python -c "import sys, json; print(json.load(sys.stdin)['password'])")
kubectl create secret generic catalog-db -n retail-app \
  --from-literal=RETAIL_CATALOG_PERSISTENCE_USER=$CATALOG_USER \
  --from-literal=RETAIL_CATALOG_PERSISTENCE_PASSWORD=$CATALOG_PASS

ORDERS_USER=$(aws secretsmanager get-secret-value --secret-id bedrock/orders-postgres --query 'SecretString' --output text | python -c "import sys, json; print(json.load(sys.stdin)['username'])")
ORDERS_PASS=$(aws secretsmanager get-secret-value --secret-id bedrock/orders-postgres --query 'SecretString' --output text | python -c "import sys, json; print(json.load(sys.stdin)['password'])")
kubectl create secret generic orders-db -n retail-app \
  --from-literal=RETAIL_ORDERS_PERSISTENCE_USERNAME=$ORDERS_USER \
  --from-literal=RETAIL_ORDERS_PERSISTENCE_PASSWORD=$ORDERS_PASS
```

### 6. Install the AWS Load Balancer Controller
```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=<bedrock-lbc-role ARN — see main.tf or AWS console>

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=project-bedrock-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=$(terraform output -raw vpc_id)
```

### 7. Deploy the application
```bash
git clone https://github.com/aws-containers/retail-store-sample-app
cd retail-store-sample-app/src/app/chart
helm dependency build
cd ../../../..
helm install retail-store retail-store-sample-app/src/app/chart \
  -n retail-app \
  -f helm-values/retail-store-values.yaml
```

### 8. Expose via Ingress
```bash
kubectl apply -f k8s/base/ingress.yaml
kubectl get ingress -n retail-app
```
Wait a couple of minutes for the ALB to provision, then the `ADDRESS` column gives you the public URL.

## CI/CD pipeline

- **On pull request** (touching `terraform/**`): runs `terraform plan`, posts the output as a PR comment
- **On merge to `main`**: runs `terraform apply` automatically
- Authenticated via GitHub OIDC → IAM role `bedrock-github-actions` (no long-lived AWS keys stored in GitHub)
- ⚠️ Note: the GitHub Actions role currently uses `AdministratorAccess` for simplicity, since this pipeline needs broad provisioning rights across VPC/EKS/RDS/IAM/Lambda/S3. In a production setting this would be scoped tighter.

To trigger it: open a PR against `main` with a Terraform change, watch the Actions tab for the plan comment, then merge to apply.

## Teardown

**Order matters** — tear down the app layer before the infrastructure it depends on:

```bash
# 1. Remove the application
helm uninstall retail-store -n retail-app
helm uninstall aws-load-balancer-controller -n kube-system
kubectl delete namespace retail-app

# 2. Destroy all Terraform-managed infrastructure
cd terraform/envs/dev
terraform destroy

# 3. Manual cleanup (Terraform doesn't manage these)
aws s3 rm s3://bedrock-assets-charity2025 --recursive
aws s3api delete-bucket --bucket bedrock-assets-charity2025

aws s3 rm s3://bedrock-tfstate-charity2025 --recursive
aws s3api delete-bucket --bucket bedrock-tfstate-charity2025

aws logs delete-log-group --log-group-name /aws/eks/project-bedrock-cluster/cluster
aws logs delete-log-group --log-group-name /aws/containerinsights/project-bedrock-cluster/application
aws logs delete-log-group --log-group-name /aws/containerinsights/project-bedrock-cluster/performance
aws logs delete-log-group --log-group-name /aws/lambda/bedrock-asset-processor
```

### Rotate/deactivate the grading access key when grading is complete
```bash
aws iam update-access-key --user-name bedrock-dev-view --access-key-id <ACCESS_KEY_ID> --status Inactive
```

## Cost notes

Running continuously, this environment costs roughly:
- EKS control plane: ~$0.10/hr
- 2× t3.small nodes: ~$0.04/hr combined
- NAT gateway: ~$0.045/hr + data processing
- 2× RDS db.t4g.micro: ~$0.03/hr combined
- ALB: ~$0.025/hr + LCU charges

An AWS Budget is configured at $20/month with an 80% threshold email alert, scoped to resources tagged `Project: tinyuka-2025-capstone`.
