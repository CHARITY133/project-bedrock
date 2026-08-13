terraform {
  required_version = ">= 1.11"

  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket       = "bedrock-tfstate-charity2025"
    key          = "project-bedrock/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true   # native S3 locking, Terraform 1.11+ — no DynamoDB table needed
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "tinyuka-2025-capstone"
    }
  }
}