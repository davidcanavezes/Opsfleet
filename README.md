# Opsfleet – Technical Assignment

This repository contains the solution for the growing startup and Innovate Inc. infrastructure assignment.

## Structure

- `terraform/` – Infrastructure as Code (EKS, VPC, Karpenter)
- `architecture/` – Architecture design document and diagram

## Overview

- AWS EKS cluster deployed via Terraform
- Karpenter for autoscaling (amd64 + arm64, Spot support)
- CI/CD workflow using GitOps approach
- Secure VPC with public, private, and isolated subnets
- Aurora PostgreSQL for database

## How to use

See:
- `terraform/README.md` for deployment instructions
- `architecture/README.md` for architecture explanation
