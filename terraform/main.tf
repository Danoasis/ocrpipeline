terraform {
  required_version = "~> 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "yourcompany-ocrpipeline-tfstate"
    key            = "ocrpipeline/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "ocrpipeline-tf-locks"
  }
}
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "ocrpipeline"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner_tag
    }
  }
}
