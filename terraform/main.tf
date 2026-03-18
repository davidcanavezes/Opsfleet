data "aws_availability_zones" "available" {
  # Exclude Local Zones and Wavelength Zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

