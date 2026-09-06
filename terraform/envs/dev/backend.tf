terraform {
  required_version = ">= 1.11"
  backend "s3" {
    bucket       = "bedrock-tfstate-alt-soe-tin-025-0082-v2"
    key          = "project-bedrock/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
