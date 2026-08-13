# Project Bedrock

InnovateMart's EKS deployment — Tinyuka capstone.

## Before you run terraform init

1. Manually create the state bucket (one-time, see step 4 below).
2. Edit `terraform/envs/dev/backend.tf` and replace
   `bedrock-tfstate-REPLACE_WITH_YOUR_STUDENT_ID` with your actual bucket name.
3. `cd terraform/envs/dev && terraform init`

## Student ID / suffix used in this project
`REPLACE_ME`

(Update this line and the backend.tf bucket name together, then delete this note.)
